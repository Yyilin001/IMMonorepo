package com.xmtx.im;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileNotFoundException;

public class DocumentOutputTestProvider extends ContentProvider {
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return uri.getLastPathSegment().endsWith(".jpg") ? "image/jpeg" : "text/plain"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) {
        MatrixCursor rows = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        rows.addRow(new Object[]{"说明.txt", null}); return rows;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (uri.getLastPathSegment().matches("export-[a-zA-Z0-9-]+\\.txt")) return ParcelFileDescriptor.open(new File(getContext().getFilesDir(), uri.getLastPathSegment()), ParcelFileDescriptor.parseMode(mode));
        if (!("composer-document.txt".equals(uri.getLastPathSegment()) || "composer-photo-0.jpg".equals(uri.getLastPathSegment()) || "composer-photo-1.jpg".equals(uri.getLastPathSegment())) || !"r".equals(mode)) throw new FileNotFoundException();
        return ParcelFileDescriptor.open(new File(getContext().getFilesDir(), uri.getLastPathSegment()), ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public Uri insert(Uri uri, ContentValues value) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues value, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { if (uri.getLastPathSegment().matches("export-[a-zA-Z0-9-]+\\.txt")) return new File(getContext().getFilesDir(), uri.getLastPathSegment()).delete() ? 1 : 0; throw new UnsupportedOperationException(); }
}
