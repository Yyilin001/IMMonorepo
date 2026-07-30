-- A group picks its synchronization contract at creation.  The mode is never
-- updated: mixing a personal fan-out stream and a room cursor stream for the
-- same room would make duplicate/lost-message recovery needlessly ambiguous.
ALTER TABLE im_v2.rooms
    ADD COLUMN delivery_mode TEXT NOT NULL DEFAULT 'standard_fanout',
    ADD CONSTRAINT rooms_delivery_mode_check
        CHECK (delivery_mode IN ('standard_fanout', 'large_group_hybrid')),
    ADD CONSTRAINT rooms_direct_delivery_mode_check
        CHECK (room_kind = 'group' OR delivery_mode = 'standard_fanout');

ALTER TABLE im_v2.group_room_operations
    ADD COLUMN delivery_mode TEXT NOT NULL DEFAULT 'standard_fanout',
    ADD CONSTRAINT group_room_operations_delivery_mode_check
        CHECK (delivery_mode IN ('standard_fanout', 'large_group_hybrid'));

CREATE OR REPLACE FUNCTION im_v2.reject_room_delivery_mode_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.delivery_mode IS DISTINCT FROM OLD.delivery_mode THEN
        RAISE EXCEPTION 'room delivery mode is immutable';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER rooms_delivery_mode_immutable
BEFORE UPDATE OF delivery_mode ON im_v2.rooms
FOR EACH ROW EXECUTE FUNCTION im_v2.reject_room_delivery_mode_mutation();
