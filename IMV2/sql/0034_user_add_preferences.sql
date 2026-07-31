CREATE TABLE im_v2.user_add_preferences (
    user_id UUID PRIMARY KEY,
    allows_being_added BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE im_v2.user_add_preference_operations (
    actor_user_id UUID NOT NULL,
    operation_id UUID NOT NULL,
    allows_being_added BOOLEAN NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor_user_id, operation_id)
);
