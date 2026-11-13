#include <stdio.h>
#include <string.h>
#include "CSearchFileLock.h"
#include "sqlite3.h"
static int interrupt_query(void *ignored) { return 1; }
int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "sqlite";
    int32_t status = 0, native_error = 0;
    if (strcmp(mode, "sqlite") != 0) {
        // UTF-8 Chinese filename exercises the Win32 UTF-16 conversion too.
        void *lease = im_search_lock_open("probe-\xe6\xb6\x88\xe6\x81\xaf.lock", &status, &native_error);
        if (strcmp(mode, "busy") == 0) { if (lease) im_search_lock_close(lease); return status == 1 ? 0 : 2; }
        if (!lease || status != 0) return 3;
        if (strcmp(mode, "hold") == 0) { puts("locked"); fflush(stdout); (void)getchar(); }
        im_search_lock_close(lease); return 0;
    }
    sqlite3 *db = NULL;
    if (sqlite3_open("probe.sqlite", &db) != SQLITE_OK) return 10;
    if (!sqlite3_compileoption_used("ENABLE_FTS5")) return 11;
    const char *sql = "PRAGMA journal_mode=WAL; CREATE VIRTUAL TABLE messages USING fts5(body); INSERT INTO messages VALUES('shared runtime');";
    if (sqlite3_exec(db, sql, NULL, NULL, NULL) != SQLITE_OK) return 12;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &statement, NULL) != SQLITE_OK) return 17;
    if (sqlite3_step(statement) != SQLITE_ROW || strcmp((const char *)sqlite3_column_text(statement, 0), "wal") != 0) return 18;
    sqlite3_finalize(statement); statement = NULL;
    if (sqlite3_prepare_v2(db, "SELECT count(*) FROM messages WHERE messages MATCH 'shared'", -1, &statement, NULL) != SQLITE_OK) return 13;
    if (sqlite3_step(statement) != SQLITE_ROW || sqlite3_column_int(statement, 0) != 1) return 14;
    sqlite3_finalize(statement);
    sqlite3_progress_handler(db, 10, interrupt_query, NULL);
    if (sqlite3_exec(db, "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT sum(x) FROM n", NULL, NULL, NULL) != SQLITE_INTERRUPT) return 15;
    sqlite3_progress_handler(db, 0, NULL, NULL);
    if (sqlite3_close(db) != SQLITE_OK) return 16;
    puts("SQLite FTS5, WAL and query interruption passed"); return 0;
}
