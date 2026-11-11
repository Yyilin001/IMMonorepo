package com.xmtx.im;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import java.io.File;

public class DocumentSaveTestActivity extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            if (android.os.Process.myUid() == getIntent().getIntExtra("targetUid", -1)) throw new IllegalStateException("Expected separate UID");
            if (!Intent.ACTION_CREATE_DOCUMENT.equals(getIntent().getAction()) || !"text/plain".equals(getIntent().getType()) || !"项目说明.txt".equals(getIntent().getStringExtra(Intent.EXTRA_TITLE))) throw new IllegalStateException("Expected CreateDocument contract and metadata");
            String name = "export-" + java.util.UUID.randomUUID().toString() + ".txt";
            if (!new File(getFilesDir(), name).createNewFile()) throw new IllegalStateException("Expected new destination");
            Uri uri = Uri.parse("content://com.xmtx.im.android.test.documents/" + name);
            Intent result = new Intent().setData(uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION).putExtra("isolated", true);
            result.setClipData(ClipData.newRawUri("new document", uri));setResult(RESULT_OK, result);
        } catch (Exception error) { setResult(RESULT_CANCELED, new Intent().putExtra("failure", error.toString())); }
        finish();
    }
}
