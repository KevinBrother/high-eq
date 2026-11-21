-- Never decrypt a platform credential to populate a management list.
ALTER TABLE model_configs ADD key_last_four text NOT NULL DEFAULT '' CHECK(length(key_last_four)<=4);
