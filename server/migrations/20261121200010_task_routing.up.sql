BEGIN;
ALTER TABLE model_routes ADD moderation_model uuid REFERENCES model_configs;
CREATE TRIGGER route_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON model_routes FOR EACH STATEMENT EXECUTE FUNCTION bump_gateway_revision();
-- NULL is unpriced, not free. Snapshot the selected tariff per attempt.
ALTER TABLE model_configs ADD input_cny_per_million numeric(12,6) CHECK(input_cny_per_million>=0),
 ADD output_cny_per_million numeric(12,6) CHECK(output_cny_per_million>=0);
ALTER TABLE ai_calls ADD operation_id uuid;
COMMIT;
