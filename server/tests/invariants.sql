-- Synthetic opaque bytes stand in for encryption envelopes; cryptography belongs to T04.
DO $$
DECLARE
  a uuid := gen_random_uuid(); b uuid := gen_random_uuid(); p uuid := gen_random_uuid();
  r uuid := gen_random_uuid(); s uuid := gen_random_uuid(); model uuid := gen_random_uuid();
  m uuid := gen_random_uuid(); t timestamptz := '2026-01-01T00:00:00Z';
BEGIN
  INSERT INTO users(id, age_confirmed_at) VALUES (a,t),(b,t);
  INSERT INTO contacts(id,user_id,profile_enc) VALUES (p,a,'x');
  INSERT INTO activities(id,user_id,contact_id,kind) VALUES(r,a,p,'review') RETURNING source_id INTO s;
  BEGIN
    INSERT INTO activities(user_id,contact_id,kind) VALUES(b,p,'review');
    RAISE EXCEPTION 'cross-account contact accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  INSERT INTO scores(id,activity_id,activity_kind,detail_enc) VALUES(s,r,'review','x');
  INSERT INTO growth_scores(score_id,kind,nvc_enc,emotion_enc) VALUES(s,'review','x','x');
  INSERT INTO model_configs(id,name,endpoint,api_key_enc) VALUES(model,'fake','test','x');
  INSERT INTO ai_calls(activity_id,model_id,task,outcome,score_id) VALUES(r,model,'scoring','ok',s);
  INSERT INTO manual_marks(user_id,accepted_at,mark_enc) VALUES(a,t,'x') RETURNING id INTO m;
  INSERT INTO mark_requests(user_id,request_id,mark_id) VALUES(a,gen_random_uuid(),m),(a,gen_random_uuid(),m);
  BEGIN
    INSERT INTO mark_requests(user_id,request_id,mark_id) VALUES(b,gen_random_uuid(),m);
    RAISE EXCEPTION 'cross-account mark retry accepted';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  INSERT INTO manual_marks(user_id,accepted_at,mark_enc) VALUES(b,t,'x');
  BEGIN
    INSERT INTO manual_marks(user_id,accepted_at,mark_enc) VALUES(a,t+interval '59.999 seconds','x');
    RAISE EXCEPTION 'duplicate mark accepted';
  EXCEPTION WHEN exclusion_violation THEN NULL; END;
  INSERT INTO manual_marks(user_id,accepted_at,mark_enc) VALUES(a,t+interval '60 seconds','x');
  INSERT INTO activities(id,user_id,kind) VALUES(m,a,'drill') RETURNING source_id INTO s;
  INSERT INTO scores(id,activity_id,activity_kind,detail_enc) VALUES(s,m,'drill','x');
  BEGIN
    INSERT INTO growth_scores(score_id,kind,nvc_enc,emotion_enc) VALUES(s,'practice','x','x');
    RAISE EXCEPTION 'single-item score counted toward growth';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  DELETE FROM activities WHERE id=r;
  IF EXISTS(SELECT FROM growth_scores) OR EXISTS(SELECT FROM ai_calls) THEN RAISE EXCEPTION 'orphan copies'; END IF;
  BEGIN
    INSERT INTO scores(id,activity_id,activity_kind,detail_enc) VALUES(gen_random_uuid(),r,'review','x');
    RAISE EXCEPTION 'deleted source recreated by replay';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  DELETE FROM users WHERE id=a;
  IF EXISTS(SELECT FROM scores) OR EXISTS(SELECT FROM manual_marks WHERE user_id=a) THEN RAISE EXCEPTION 'account cascade failed'; END IF;
  IF NOT EXISTS(SELECT FROM manual_marks WHERE user_id=b) THEN RAISE EXCEPTION 'other account affected'; END IF;
END $$;

DO $$
DECLARE
  owner uuid := gen_random_uuid(); outsider uuid := gen_random_uuid(); invoice uuid := gen_random_uuid();
  sess uuid := gen_random_uuid(); msg uuid := gen_random_uuid(); t timestamptz := '2026-01-01T15:59:00Z';
BEGIN
  INSERT INTO users(id,age_confirmed_at) VALUES(owner,t),(outsider,t);
  INSERT INTO orders(id,user_id,platform,transaction_hmac,product_code,amount_fen,state)
    VALUES(invoice,owner,'apple','opaque','monthly',100,'paid');
  BEGIN
    INSERT INTO entitlements VALUES(invoice,outsider,t,t+interval '1 month');
    RAISE EXCEPTION 'purchase granted to a different account';
  EXCEPTION WHEN foreign_key_violation THEN NULL; END;
  INSERT INTO entitlements VALUES(invoice,owner,t,t+interval '1 month');
  INSERT INTO activities(id,user_id,kind) VALUES(sess,owner,'practice');
  INSERT INTO practice_messages(activity_id,kind,client_message_id,seq,role,content_enc)
    VALUES(sess,'practice',msg,1,'user','x'),(sess,'practice',msg,2,'assistant','x');
  BEGIN
    INSERT INTO practice_messages(activity_id,kind,client_message_id,seq,role,content_enc) VALUES(sess,'practice',msg,3,'user','y');
    RAISE EXCEPTION 'message retry accepted twice';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  INSERT INTO quota_ledger VALUES(sess,DATE '2026-01-01',t,NULL);
  INSERT INTO daily_quota_usage VALUES(owner,'practice',DATE '2026-01-01',1);
  BEGIN
    INSERT INTO quota_ledger VALUES(sess,DATE '2026-01-02',t+interval '2 minutes',NULL);
    RAISE EXCEPTION 'charged again after midnight';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  UPDATE quota_ledger SET refunded_at=t+interval '2 minutes' WHERE activity_id=sess AND refunded_at IS NULL;
  IF NOT EXISTS(SELECT FROM quota_ledger WHERE activity_id=sess AND charged_day='2026-01-01' AND refunded_at IS NOT NULL)
    THEN RAISE EXCEPTION 'original charge day lost'; END IF;
  DELETE FROM users WHERE id=owner;
  IF EXISTS(SELECT FROM entitlements WHERE order_id=invoice) OR NOT EXISTS(SELECT FROM orders WHERE id=invoice AND user_id IS NULL)
    THEN RAISE EXCEPTION 'order was not anonymized'; END IF;
END $$;
