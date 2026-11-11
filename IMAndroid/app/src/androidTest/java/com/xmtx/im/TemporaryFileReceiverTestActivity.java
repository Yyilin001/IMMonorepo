package com.xmtx.im;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.InputStream;
import java.io.ByteArrayOutputStream;

/** An unrelated UID reads after the source route may already have closed. */
public class TemporaryFileReceiverTestActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        new Handler(Looper.getMainLooper()).postDelayed(this::readFile, 700);
    }
    private void readFile() {
        try {
            if (android.os.Process.myUid() == getIntent().getIntExtra("targetUid", -1)) throw new IllegalStateException("Expected another UID");
            Uri uri = getIntent().getData();
            if (!(Intent.ACTION_VIEW.equals(getIntent().getAction()) || Intent.ACTION_SEND.equals(getIntent().getAction()))) throw new IllegalStateException("Unexpected action");
            if (Intent.ACTION_SEND.equals(getIntent().getAction()) && !uri.equals(getIntent().getParcelableExtra(Intent.EXTRA_STREAM))) throw new IllegalStateException("Stream mismatch");
            if (checkUriPermission(uri, android.os.Process.myPid(), android.os.Process.myUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) != PackageManager.PERMISSION_GRANTED) throw new IllegalStateException("Missing read grant");
            if (checkUriPermission(uri, android.os.Process.myPid(), android.os.Process.myUid(), Intent.FLAG_GRANT_WRITE_URI_PERMISSION) == PackageManager.PERMISSION_GRANTED) throw new IllegalStateException("Unexpected write grant");
            boolean denied = false;
            try (ParcelFileDescriptor fd = getContentResolver().openFileDescriptor(uri, "rw")) { }
            catch (Exception expected) { denied = true; }
            if (!denied) throw new IllegalStateException("Write accepted");
            if (!"text/plain".equals(getContentResolver().getType(uri))) throw new IllegalStateException("MIME mismatch");
            try (android.database.Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (!cursor.moveToFirst() || !"项目说明.txt".equals(cursor.getString(0))) throw new IllegalStateException("Display name mismatch");
            }
            try (InputStream in = getContentResolver().openInputStream(uri); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[4096];int n;
                while ((n = in.read(buffer)) >= 0) out.write(buffer, 0, n);
                setResult(RESULT_OK, new Intent().putExtra("contents", out.toString("UTF-8")).putExtra("isolated", true));
            }
        } catch (Exception error) { setResult(RESULT_CANCELED, new Intent().putExtra("failure", error.toString())); }
        finish();
    }
}
