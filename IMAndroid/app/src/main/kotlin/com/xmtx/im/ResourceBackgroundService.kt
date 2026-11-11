package com.xmtx.im

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import androidx.core.net.toUri
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.xmtx.im.platform.AccountResourceActivity
import com.xmtx.im.platform.ResourceBackgroundRunResult
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

enum class ResourceBackgroundState { Unavailable,Idle,Starting,Running,Stopping,Completed,BudgetExpired,Stopped,Failed;
    val active get()=this in setOf(Starting,Running,Stopping)
}

/** Opaque process-local account binding. No credentials, URLs, file paths or business content enter an Intent. */
internal class ResourceBackgroundSession(val token:String,val activity:AccountResourceActivity) {
    private val mutable=MutableStateFlow(ResourceBackgroundState.Idle)
    val state=mutable.asStateFlow()
    private var job:Job?=null;private var closed=false
    @Synchronized fun request():Boolean {
        if(closed || mutable.value.active) return false
        mutable.value=ResourceBackgroundState.Starting;return true
    }
    @Synchronized fun attach(value:Job):Boolean {
        if(closed || mutable.value!=ResourceBackgroundState.Starting) return false
        job=value;mutable.value=ResourceBackgroundState.Running;return true
    }
    @Synchronized fun stop() {
        if(mutable.value==ResourceBackgroundState.Starting && job==null) mutable.value=ResourceBackgroundState.Stopped
        else if(mutable.value.active) {mutable.value=ResourceBackgroundState.Stopping;job?.cancel()}
    }
    @Synchronized fun finished(value:Job?,result:ResourceBackgroundState) {
        if(job===value) {job=null;mutable.value=if(closed) ResourceBackgroundState.Unavailable else result}
    }
    @Synchronized fun close() {closed=true;job?.cancel();mutable.value=ResourceBackgroundState.Unavailable}
}

internal object ResourceBackgroundSessions {
    private val sessions=ConcurrentHashMap<String,ResourceBackgroundSession>()
    fun register(activity:AccountResourceActivity):ResourceBackgroundSession {
        val value=ResourceBackgroundSession(UUID.randomUUID().toString(),activity);sessions[value.token]=value;return value
    }
    fun find(token:String?)=token?.let {sessions[it]}
    fun remove(value:ResourceBackgroundSession) {sessions.remove(value.token,value);value.close()}
    fun start(context:Context,value:ResourceBackgroundSession) {
        if(sessions[value.token]!==value || !value.request()) return
        try {ContextCompat.startForegroundService(context,Intent(context,ResourceBackgroundService::class.java).putExtra("session",value.token))}
        catch(_:RuntimeException) {value.finished(null,ResourceBackgroundState.Failed)}
    }
}

/** Explicit visible-start service. Process death invalidates its binding; journal recovery remains authoritative. */
class ResourceBackgroundService:Service() {
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private var current:Job?=null
    private var currentSession:ResourceBackgroundSession?=null
    override fun onBind(intent:Intent?):IBinder?=null
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        val session=ResourceBackgroundSessions.find(intent?.getStringExtra("session"))
        if(intent?.action==STOP) {
            session?.stop();if(current==null) stopSelf(startId)
            return START_NOT_STICKY
        }
        if(session==null || session.state.value!=ResourceBackgroundState.Starting) {
            if(current==null) stopSelf(startId)
            return START_NOT_STICKY
        }
        try {ServiceCompat.startForeground(this,NOTIFICATION,notification(session),ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)}
        catch(_:RuntimeException) {session.finished(null,ResourceBackgroundState.Failed);current?.cancel();stopSelf(startId);return START_NOT_STICKY}
        val previous=current;previous?.cancel()
        lateinit var execution:Job
        execution=scope.launch(start=CoroutineStart.LAZY) {
            var result=ResourceBackgroundState.Stopped
            var awake:PowerManager.WakeLock?=null
            try {
                previous?.join();ensureActive()
                // A foreground service alone does not keep the CPU awake with the screen off.
                // Bound this lock independently of coroutine cleanup and never embed account identifiers.
                awake=getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"IM:resource-transfer").apply {
                    setReferenceCounted(false);acquire(15*60_000L)
                }
                result=when(session.activity.runBackground()) {
                    ResourceBackgroundRunResult.Completed->ResourceBackgroundState.Completed
                    ResourceBackgroundRunResult.BudgetExpired->ResourceBackgroundState.BudgetExpired
                }
            } catch(error:CancellationException) {throw error}
            catch(_:Exception) {result=ResourceBackgroundState.Failed}
            finally {
                awake?.let {if(it.isHeld) it.release()}
                session.finished(execution,result)
                if(current===execution) {
                    current=null;currentSession=null
                    ServiceCompat.stopForeground(this@ResourceBackgroundService,ServiceCompat.STOP_FOREGROUND_REMOVE)
                    // A stop action is another start ID; this execution still owns the only current task.
                    stopSelf()
                }
            }
        }
        if(!session.attach(execution)) {execution.cancel();if(current==null) {ServiceCompat.stopForeground(this,ServiceCompat.STOP_FOREGROUND_REMOVE);stopSelf(startId)};return START_NOT_STICKY}
        current=execution;currentSession=session;execution.start()
        return START_NOT_STICKY
    }
    private fun notification(session:ResourceBackgroundSession):Notification {
        val manager=getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,"资源传输",NotificationManager.IMPORTANCE_LOW))
        val content=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop=PendingIntent.getService(this,0,Intent(this,ResourceBackgroundService::class.java).setAction(STOP)
            .setData("im-resource://background/${session.token}".toUri()).putExtra("session",session.token),PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this,CHANNEL).setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("资源传输").setContentText("正在后台处理资源，可随时停止后台执行")
            .setContentIntent(content).setOngoing(true).setOnlyAlertOnce(true).setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .addAction(0,"停止后台执行",stop).build()
    }
    override fun onTimeout(startId:Int,fgsType:Int) {
        currentSession?.stop();current?.cancel()
        ServiceCompat.stopForeground(this,ServiceCompat.STOP_FOREGROUND_REMOVE);stopSelf(startId)
    }
    override fun onDestroy() {currentSession?.stop();scope.cancel();super.onDestroy()}
    companion object {
        private const val CHANNEL="resource-transfers"
        private const val NOTIFICATION=2301
        private const val STOP="com.xmtx.im.STOP_RESOURCE_BACKGROUND"
    }
}
