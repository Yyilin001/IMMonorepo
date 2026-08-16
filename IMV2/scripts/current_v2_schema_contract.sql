SELECT to_regnamespace('im_v2') IS NOT NULL
   AND EXISTS (
     SELECT 1
     FROM information_schema.columns
     WHERE table_schema = 'im_v2'
       AND table_name = 'schema_contract'
       AND column_name = 'schema_id'
       AND is_nullable = 'NO'
       AND column_default = '''im-v2-current-1''::text'
   )
   AND EXISTS (
     SELECT 1
     FROM pg_constraint AS constraint_record
     JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
     JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
     WHERE namespace.nspname = 'im_v2'
       AND relation.relname = 'schema_contract'
       AND constraint_record.contype = 'c'
       AND pg_get_constraintdef(constraint_record.oid) LIKE '%im-v2-current-1%'
   )
   AND to_regclass('im_v2.local_schema_migrations') IS NULL;
