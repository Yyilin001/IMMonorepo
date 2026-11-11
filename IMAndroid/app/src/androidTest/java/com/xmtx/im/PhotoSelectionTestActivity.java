package com.xmtx.im;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import java.io.File;
import java.io.FileOutputStream;

/** Separate-UID photo picker returns two ordered read grants through ClipData. */
public class PhotoSelectionTestActivity extends Activity {
    @Override public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        try {
            if (android.os.Process.myUid() == getIntent().getIntExtra("targetUid", -1)) throw new IllegalStateException("Expected separate UID");
            Uri[] uris = new Uri[2];
            for (int i = 0; i < 2; i++) {
                String name = "composer-photo-" + i + ".jpg";
                Bitmap bitmap = Bitmap.createBitmap(80, 60, Bitmap.Config.ARGB_8888);
                try {
                    bitmap.eraseColor(i == 0 ? Color.RED : Color.BLUE);
                    try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(), name))) { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, out); }
                } finally { bitmap.recycle(); }
                uris[i] = Uri.parse("content://com.xmtx.im.android.test.documents/" + name);
            }
            ClipData data = ClipData.newRawUri("photos", uris[0]); data.addItem(new ClipData.Item(uris[1]));
            Intent result = new Intent().addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).putExtra("isolated", true);result.setClipData(data);
            setResult(RESULT_OK, result);
        } catch (Exception error) { setResult(RESULT_CANCELED, new Intent().putExtra("failure", error.toString())); }
        finish();
    }
}
