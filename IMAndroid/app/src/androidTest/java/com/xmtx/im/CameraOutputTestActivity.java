package com.xmtx.im;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.provider.MediaStore;
import java.io.OutputStream;

/** Separate test-APK UID. Uses only framework classes, without the target APK's runtime. */
public class CameraOutputTestActivity extends Activity {
    @SuppressWarnings("deprecation")
    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            if (android.os.Process.myUid() == getIntent().getIntExtra("targetUid", -1))
                throw new IllegalStateException("Camera must run as a different UID");
            Uri output = getIntent().getParcelableExtra(MediaStore.EXTRA_OUTPUT);
            if (output == null) throw new IllegalArgumentException("Missing camera output");
            Uri sibling = output.buildUpon().path("/capture/ungranted.jpg").build();
            boolean denied = false;
            try (OutputStream stream = getContentResolver().openOutputStream(sibling, "w")) {
                // This neighboring file is deliberately outside the granted URI.
            } catch (SecurityException expected) { denied = true; }
            if (!denied) throw new IllegalStateException("Unexpected access to neighboring file");
            Bitmap bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888);
            try {
                bitmap.eraseColor(Color.GREEN);
                try (OutputStream stream = getContentResolver().openOutputStream(output, "w")) {
                    if (stream == null || !bitmap.compress(Bitmap.CompressFormat.JPEG, 95, stream))
                        throw new IllegalStateException("Could not write camera output");
                }
            } finally { bitmap.recycle(); }
            setResult(RESULT_OK, new Intent().putExtra("isolated", true));
        } catch (Exception error) {
            setResult(RESULT_CANCELED, new Intent().putExtra("failure", error.getClass().getSimpleName() + ": " + error.getMessage()));
        }
        finish();
    }
}
