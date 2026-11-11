package com.xmtx.im;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import java.io.File;
import java.io.FileOutputStream;

/** A document picker in the separate test APK returns exactly one read grant. */
public class DocumentOutputTestActivity extends Activity {
    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            if (android.os.Process.myUid() == getIntent().getIntExtra("targetUid", -1))
                throw new IllegalStateException("Picker must run as another UID");
            if (!Intent.ACTION_OPEN_DOCUMENT.equals(getIntent().getAction()))
                throw new IllegalStateException("Expected the OpenDocument contract");
            try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), "composer-document.txt"))) {
                out.write("系统文件选择结果".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            }
            Uri uri = Uri.parse("content://com.xmtx.im.android.test.documents/composer-document.txt");
            Intent result = new Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).putExtra("isolated", true);
            result.setClipData(ClipData.newRawUri("document", uri));
            setResult(RESULT_OK, result);
        } catch (Exception error) {
            setResult(RESULT_CANCELED, new Intent().putExtra("failure", error.toString()));
        }
        finish();
    }
}
