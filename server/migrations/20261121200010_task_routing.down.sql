BEGIN;
ALTER TABLE ai_calls DROP operation_id;
ALTER TABLE model_configs DROP input_cny_per_million, DROP output_cny_per_million;
DROP TRIGGER route_changed ON model_routes;
ALTER TABLE model_routes DROP moderation_model;
COMMIT;
