-- =====================================================================
-- 시나리오 A·B·C 단계별 실행 (01 → 02 → 05 실행 후. 03과는 독립)
--   통째로: sqlite3 majung.db ".read majung_db/06_scenarios_abc.sql"
--   한 단계씩: 각 @step 아래 SQL을 sqlite3에 붙여 넣기
-- 규칙
--   * 외출이 방문 2개 이상이면 trip을 먼저 만들고 visit.trip_id로 묶는다 (B, C)
--   * 후보는 purpose(meet/parking)를 꼭 넣고, 순위는 purpose별로 매긴다
--   * 후보 id는 숫자로 박지 않고 (visit_id, access_point_id)로 찾는다
--   * visit을 고칠 때는 WHERE version = (내가 본 값) → 끝난 뒤 version이 기대값이면 모든 단계 성공
--   * 주석의 @scenario/@step/@desc/@result는 설명서 PDF가 읽는 표시
-- =====================================================================

PRAGMA foreign_keys = ON;

-- @scenario A | 운전자가 목적지에서 가족 픽업 | 아빠가 집에서 출발해 쇼핑몰에 있는 엄마를 데리러 가요. 맑은 날이에요.

-- @step A-1 | 출발 전: 목적지 입력, 만남·주차 장소 추천
-- @desc 방문을 만들고 추천 후보를 저장해요. 만남 후보(승하차 구역 + 로비)와 주차 후보(주차장)가 같이 들어가고, purpose로 구분해요. 순위도 purpose별로 따로 매겨요.
-- @result 만남 후보: 서문 1순위, 북문 2순위, 동문 제외 / 주차 후보: B2 1순위
BEGIN;
INSERT INTO visit (id, facility_id, mode, driver_device_id, weather_json, expires_at)
VALUES ('visit-a-001', 1, 'pickup', 'device-car-001',
        '{"condition":"clear","temp_c":18}', datetime('now', '+1 day'));
INSERT INTO participant (visit_id, role, token, display_name)
VALUES ('visit-a-001', 'driver', 'tok-a-driver', '아빠');
INSERT INTO candidate (visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json, excluded_reason)
VALUES
  ('visit-a-001', 'meet',    1, 1,    1,    1,    0.88, '["맑음","가장 가까움","도보 2분"]', NULL),
  ('visit-a-001', 'meet',    2, 2,    3,    2,    0.80, '["지붕 있음","도보 1분"]', NULL),
  ('visit-a-001', 'meet',    3, NULL, NULL, NULL, NULL, NULL, '승하차 금지 구역'),
  ('visit-a-001', 'parking', 4, NULL, NULL, 1,    0.90, '["실내 주차","엘리베이터 가까움"]', NULL);
COMMIT;

SELECT c.purpose, c.rank, ap.name AS access_point, ws.name AS wait_spot, c.excluded_reason
  FROM candidate c
  JOIN access_point ap ON ap.id = c.access_point_id
  LEFT JOIN wait_spot ws ON ws.id = c.wait_spot_id
 WHERE c.visit_id = 'visit-a-001'
 ORDER BY c.purpose, c.rank IS NULL, c.rank;

-- @step A-2 | 목적지 결정, 동승자에게 링크 전달
-- @desc 아빠가 서문을 고르면 version 1 → 2. 엄마를 참여자로 넣으면 token이 생기고, 이 값이 링크에 들어가요.
-- @result version 2, 엄마 링크(tok-a-passenger)로 열면 서문 승하차 구역 / 1층 서문 로비
UPDATE visit
   SET confirmed_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-a-001' AND access_point_id = 1),
       version = version + 1
 WHERE id = 'visit-a-001' AND version = 1;

INSERT INTO participant (visit_id, role, token, display_name, conditions_json, status)
VALUES ('visit-a-001', 'passenger', 'tok-a-passenger', '엄마', '{"stroller":true}', 'preparing');

SELECT p.display_name, v.visit_id, v.version, v.access_point_name, v.wait_spot_name
  FROM participant p JOIN v_visit_card v ON v.visit_id = p.visit_id
 WHERE p.token = 'tok-a-passenger';

-- @step A-3 | 운전자 이동, 동승자가 위치 확인
-- @desc 픽업 시작을 이력에 남기고 visit 상태를 바꿔요(version 3). 차 위치는 vehicle_update에 쌓고 최신값은 visit에 복사해요.
-- @result 방문 카드에 status moving, 남은 시간 900초(15분)
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-a-001', 'pickup_started', (SELECT id FROM participant WHERE token = 'tok-a-driver'), 'req-a-start');
UPDATE visit SET status = 'moving', current_stage = 'pickup_started', version = version + 1
 WHERE id = 'visit-a-001' AND version = 2;
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-a-001', 37.5300, 127.2000, 900, 'set', 1);
UPDATE visit SET last_lat = 37.5300, last_lng = 127.2000, last_eta_sec = 900,
                 last_nav_result = 'set', last_vehicle_at = datetime('now')
 WHERE id = 'visit-a-001';
COMMIT;

SELECT status, current_stage, last_lat, last_lng, last_eta_sec
  FROM v_visit_card WHERE visit_id = 'visit-a-001';

-- @step A-4 | 만남: 운전자가 확인
-- @desc 아빠가 '만났어요'를 누르면 도착·탑승 이력이 쌓이고 visit은 boarded(version 4)가 돼요.
-- @result status boarded, stage_event 3줄 (pickup_started, arrived, boarded)
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-a-001', 'arrived', (SELECT id FROM participant WHERE token = 'tok-a-driver'), 'req-a-arrived'),
       ('visit-a-001', 'boarded', (SELECT id FROM participant WHERE token = 'tok-a-driver'), 'req-a-boarded');
UPDATE visit SET status = 'boarded', current_stage = 'boarded', version = version + 1
 WHERE id = 'visit-a-001' AND version = 3;
COMMIT;

SELECT stage, created_at FROM stage_event WHERE visit_id = 'visit-a-001' ORDER BY id;

-- @step A-5 | 주차 장소 추천, 주차 완료 저장
-- @desc A-1에서 저장한 주차 후보 중 1순위를 골라 parking_candidate_id에 넣고, 주차 완료(version 5) 뒤 방문을 닫아요(version 6).
-- @result 지하주차장 B2 입구에 주차, status ended, version 6, 방문 기록 1줄
SELECT c.rank, ap.name, c.reasons_json
  FROM candidate c JOIN access_point ap ON ap.id = c.access_point_id
 WHERE c.visit_id = 'visit-a-001' AND c.purpose = 'parking' AND c.excluded_reason IS NULL
 ORDER BY c.rank;

BEGIN;
UPDATE visit
   SET parking_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-a-001' AND access_point_id = 4),
       current_stage = 'parked', version = version + 1
 WHERE id = 'visit-a-001' AND version = 4;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-a-001', 'parked', (SELECT id FROM participant WHERE token = 'tok-a-driver'), 'req-a-parked');
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-a-001' AND version = 5;
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, confirmed_candidate_id FROM visit WHERE id = 'visit-a-001';
COMMIT;

SELECT v.status, v.version, ap.name AS parked_at
  FROM visit v
  JOIN candidate c     ON c.id  = v.parking_candidate_id
  JOIN access_point ap ON ap.id = c.access_point_id
 WHERE v.id = 'visit-a-001';

-- @scenario B | 운전자와 동승자가 함께 출발 | 비 오는 날, 아빠가 엄마를 쇼핑몰에 내려주고 주차해요. 나중에 주차장에서 다시 만나요. 내려주기와 만나기는 방문 2개로 나누고 trip으로 묶어요. 엄마는 외출 링크 하나로 끝까지 봐요.

-- @step B-1 | 목적지 선택, 내려줄 곳·주차 자리 추천
-- @desc 외출(trip)을 먼저 만들고 공유 링크(share_token)를 붙여요. 엄마도 차에 타고 있으니 처음부터 참여자 2명이에요. 비가 와서 지붕 있는 북문과 실내 주차장이 1순위예요.
-- @result 만남(내려주기) 후보 북문 1순위, 주차 후보 B2 1순위
BEGIN;
INSERT INTO trip (id, driver_device_id, share_token)
VALUES ('trip-b-001', 'device-car-001', 'tok-trip-b');
INSERT INTO visit (id, trip_id, facility_id, mode, driver_device_id, weather_json, expires_at)
VALUES ('visit-b-drop', 'trip-b-001', 1, 'dropoff', 'device-car-001',
        '{"condition":"rain","temp_c":14}', datetime('now', '+1 day'));
INSERT INTO participant (visit_id, role, token, display_name, conditions_json)
VALUES ('visit-b-drop', 'driver',    'tok-b-driver',    '아빠', NULL),
       ('visit-b-drop', 'passenger', 'tok-b-passenger', '엄마', '{"stroller":true,"prefer_indoor":true}');
INSERT INTO candidate (visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json, excluded_reason)
VALUES
  ('visit-b-drop', 'meet',    2, 2,    3,    1,    0.93, '["비","지붕 있음","유모차 실내 연결"]', NULL),
  ('visit-b-drop', 'meet',    1, 1,    1,    2,    0.55, '["가까움","비 맞음"]', NULL),
  ('visit-b-drop', 'meet',    3, NULL, NULL, NULL, NULL, NULL, '승하차 금지 구역'),
  ('visit-b-drop', 'parking', 4, NULL, NULL, 1,    0.95, '["비","실내 주차","유모차 전용 주차면"]', NULL);
COMMIT;

SELECT c.purpose, c.rank, ap.name, c.reasons_json
  FROM candidate c JOIN access_point ap ON ap.id = c.access_point_id
 WHERE c.visit_id = 'visit-b-drop' AND c.excluded_reason IS NULL
 ORDER BY c.purpose, c.rank;

-- @step B-2 | 목적지 결정
-- @desc 내려줄 곳(confirmed_candidate_id)과 주차할 곳(parking_candidate_id)을 한 번에 정해요. version 1 → 2.
-- @result 북문 승하차 구역에 내리고 B2에 주차하기로 함
UPDATE visit
   SET confirmed_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-b-drop' AND access_point_id = 2),
       parking_candidate_id   = (SELECT id FROM candidate WHERE visit_id = 'visit-b-drop' AND access_point_id = 4),
       version = version + 1
 WHERE id = 'visit-b-drop' AND version = 1;

SELECT access_point_name AS dropoff_at, version FROM v_visit_card WHERE visit_id = 'visit-b-drop';

-- @step B-3 | 운전자 이동
-- @desc 함께 타고 출발하니 pickup_started 대신 departed 단계를 남겨요(version 3).
-- @result status moving, current_stage departed, 남은 시간 1200초
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-b-drop', 'departed', (SELECT id FROM participant WHERE token = 'tok-b-driver'), 'req-b-departed');
UPDATE visit SET status = 'moving', current_stage = 'departed', version = version + 1
 WHERE id = 'visit-b-drop' AND version = 2;
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-b-drop', 37.5200, 127.1800, 1200, 'set', 2);
UPDATE visit SET last_lat = 37.5200, last_lng = 127.1800, last_eta_sec = 1200,
                 last_nav_result = 'set', last_vehicle_at = datetime('now')
 WHERE id = 'visit-b-drop';
COMMIT;

-- @step B-4 | 동승자 내려주기 & 주차
-- @desc 문이 열리면 차량 센서가 하차 완료를 알려요(source = sensor). 그다음 주차 완료. 단계마다 version이 올라 5가 돼요.
-- @result current_stage parked, version 5, 이력: departed → dropoff_done(sensor) → parked(manual)
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, source, request_id)
VALUES ('visit-b-drop', 'dropoff_done', NULL, 'sensor', 'req-b-dropoff');
UPDATE visit SET status = 'arrived', current_stage = 'dropoff_done', version = version + 1
 WHERE id = 'visit-b-drop' AND version = 3;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-b-drop', 'parked', (SELECT id FROM participant WHERE token = 'tok-b-driver'), 'req-b-parked');
UPDATE visit SET current_stage = 'parked', version = version + 1
 WHERE id = 'visit-b-drop' AND version = 4;
COMMIT;

SELECT stage, source FROM stage_event WHERE visit_id = 'visit-b-drop' ORDER BY id;

-- @step B-5 | 시간 보내기
-- @desc 내려주기 방문은 여기서 닫아요(version 6). 각자 시간을 보내는 동안 DB에 새로 쌓이는 건 없어요.
-- @result visit-b-drop: ended, version 6
BEGIN;
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-b-drop' AND version = 5;
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, parking_candidate_id FROM visit WHERE id = 'visit-b-drop';
COMMIT;

-- @step B-6 | 운전자가 먼저 주차장에 가서 만남 장소 선택
-- @desc 같은 trip으로 픽업 방문을 새로 만들어요. 차가 B2에 있으니 B2 입구 + 가족휴게실이 1순위예요. 엄마가 처음 받은 외출 링크(tok-trip-b)를 다시 열면 새 방문이 보여요.
-- @result trip-b-001에 방문 2개 (dropoff ended, pickup created). 외출 링크 → visit-b-pick, 만남 장소 지하주차장 B2 입구 / 2층 가족휴게실
BEGIN;
INSERT INTO visit (id, trip_id, facility_id, mode, driver_device_id, weather_json, expires_at)
VALUES ('visit-b-pick', 'trip-b-001', 1, 'pickup', 'device-car-001',
        '{"condition":"rain","temp_c":13}', datetime('now', '+1 day'));
INSERT INTO participant (visit_id, role, token, display_name, current_wait_spot_id, status)
VALUES ('visit-b-pick', 'driver',    'tok-b2-driver',    '아빠', NULL, 'none'),
       ('visit-b-pick', 'passenger', 'tok-b2-passenger', '엄마', 3,    'preparing');
INSERT INTO candidate (visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json)
VALUES
  ('visit-b-pick', 'meet', 4, 3, 5, 1, 0.94, '["차가 있는 B2","엘리베이터 실내 연결","비 안 맞음"]'),
  ('visit-b-pick', 'meet', 2, 2, 3, 2, 0.80, '["지붕 있음","차를 빼야 함"]');
UPDATE visit
   SET confirmed_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-b-pick' AND access_point_id = 4),
       version = version + 1
 WHERE id = 'visit-b-pick' AND version = 1;
COMMIT;

SELECT id, mode, status, current_stage, version
  FROM visit WHERE trip_id = 'trip-b-001' ORDER BY created_at, rowid;

-- 외출 링크로 열면: 진행 중인 방문 (04의 Q11)
SELECT t.id AS trip_id, v.id AS visit_id, v.mode, v.status
  FROM trip t
  JOIN visit v ON v.trip_id = t.id
 WHERE t.share_token = 'tok-trip-b'
   AND v.status NOT IN ('ended', 'cancelled')
 ORDER BY v.created_at DESC, v.rowid DESC
 LIMIT 1;

-- @step B-7 | 만나기
-- @desc 엄마가 휴게실에서 B2로 내려오고, 아빠가 확인하면 픽업 방문도 끝나요(version 3).
-- @result visit-b-pick: ended, version 3. 엄마 status at_lobby
BEGIN;
UPDATE participant SET status = 'at_lobby', last_seen_at = datetime('now')
 WHERE token = 'tok-b2-passenger';
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-b-pick', 'arrived', (SELECT id FROM participant WHERE token = 'tok-b2-driver'), 'req-b2-arrived'),
       ('visit-b-pick', 'boarded', (SELECT id FROM participant WHERE token = 'tok-b2-driver'), 'req-b2-boarded');
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-b-pick' AND version = 2;
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, confirmed_candidate_id FROM visit WHERE id = 'visit-b-pick';
COMMIT;

SELECT id, mode, status, version FROM visit WHERE trip_id = 'trip-b-001' ORDER BY created_at, rowid;

-- @scenario C | 가족 픽업 후 바로 다른 장소로 | A처럼 엄마를 데리러 가고, 엄마는 ETA를 보고 딱 맞춰 나와요. 그다음 같이 미술관에 가는데 비가 와서 실내 주차장을 추천받아요. 방문 2개를 trip으로 묶어요.

-- @step C-1 | 출발 전: 목적지 입력, 만남 장소 추천과 결정
-- @desc 외출(trip)을 만들고, A-1과 A-2의 앞부분을 한 번에 해요. 서문을 골라 version 2.
-- @result visit-c-pick: 서문 승하차 구역 / 1층 서문 로비, version 2
BEGIN;
INSERT INTO trip (id, driver_device_id, share_token)
VALUES ('trip-c-001', 'device-car-001', 'tok-trip-c');
INSERT INTO visit (id, trip_id, facility_id, mode, driver_device_id, weather_json, expires_at)
VALUES ('visit-c-pick', 'trip-c-001', 1, 'pickup', 'device-car-001',
        '{"condition":"cloudy","temp_c":16}', datetime('now', '+1 day'));
INSERT INTO participant (visit_id, role, token, display_name)
VALUES ('visit-c-pick', 'driver', 'tok-c-driver', '아빠');
INSERT INTO candidate (visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json, excluded_reason)
VALUES
  ('visit-c-pick', 'meet', 1, 1,    1,    1,    0.86, '["가장 가까움","도보 2분"]', NULL),
  ('visit-c-pick', 'meet', 2, 2,    3,    2,    0.82, '["지붕 있음"]', NULL),
  ('visit-c-pick', 'meet', 3, NULL, NULL, NULL, NULL, NULL, '승하차 금지 구역');
UPDATE visit
   SET confirmed_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-c-pick' AND access_point_id = 1),
       version = version + 1
 WHERE id = 'visit-c-pick' AND version = 1;
COMMIT;

-- @step C-2 | 동승자에게 링크 전달
-- @desc 엄마는 지금 서문 로비 근처에 있어요(current_wait_spot_id = 1).
-- @result 링크가 열리고 is_closed = 0
INSERT INTO participant (visit_id, role, token, display_name, current_wait_spot_id, status)
VALUES ('visit-c-pick', 'passenger', 'tok-c-passenger', '엄마', 1, 'preparing');

SELECT p.role, v.id AS visit_id, v.status,
       CASE WHEN v.expires_at < datetime('now') OR v.status IN ('ended', 'cancelled')
            THEN 1 ELSE 0 END AS is_closed
  FROM participant p JOIN visit v ON v.id = p.visit_id
 WHERE p.token = 'tok-c-passenger';

-- @step C-3 | 운전자 이동, 동승자가 ETA 확인
-- @desc 차가 10분(600초) 거리예요. 엄마 화면의 판정은 '아직 기다리기'예요.
-- @result passenger_instruction = wait (600초 > 도보 120초)
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-c-pick', 'pickup_started', (SELECT id FROM participant WHERE token = 'tok-c-driver'), 'req-c-start');
UPDATE visit SET status = 'moving', current_stage = 'pickup_started', version = version + 1
 WHERE id = 'visit-c-pick' AND version = 2;
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-c-pick', 37.5320, 127.2050, 600, 'set', 1);
UPDATE visit SET last_lat = 37.5320, last_lng = 127.2050, last_eta_sec = 600,
                 last_nav_result = 'set', last_vehicle_at = datetime('now')
 WHERE id = 'visit-c-pick';
COMMIT;

SELECT last_eta_sec, walk_minutes * 60 AS walk_sec,
       CASE WHEN last_eta_sec IS NULL THEN 'no_location'
            WHEN last_eta_sec <= walk_minutes * 60 THEN 'go_now'
            ELSE 'wait' END AS passenger_instruction
  FROM v_visit_card WHERE visit_id = 'visit-c-pick';

-- @step C-4 | 제시간에 만남
-- @desc 차가 110초 거리가 되면 '이제 나오세요'(go_now). 서버가 arrival_imminent를 남기고(version 4), 엄마가 걸어 나와 딱 맞춰 만나면 방문을 닫아요(version 5).
-- @result 판정 go_now → 엄마 at_lobby → visit-c-pick ended, version 5
BEGIN;
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-c-pick', 37.5398, 127.2185, 110, 'set', 1);
UPDATE visit SET last_lat = 37.5398, last_lng = 127.2185, last_eta_sec = 110, last_vehicle_at = datetime('now')
 WHERE id = 'visit-c-pick';
INSERT INTO stage_event (visit_id, stage, source, request_id)
VALUES ('visit-c-pick', 'arrival_imminent', 'system', 'req-c-imminent');
UPDATE visit SET current_stage = 'arrival_imminent', version = version + 1
 WHERE id = 'visit-c-pick' AND version = 3;
COMMIT;

SELECT last_eta_sec, walk_minutes * 60 AS walk_sec,
       CASE WHEN last_eta_sec IS NULL THEN 'no_location'
            WHEN last_eta_sec <= walk_minutes * 60 THEN 'go_now'
            ELSE 'wait' END AS passenger_instruction
  FROM v_visit_card WHERE visit_id = 'visit-c-pick';

BEGIN;
UPDATE participant SET status = 'at_lobby', last_seen_at = datetime('now') WHERE token = 'tok-c-passenger';
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-c-pick', 'arrived', (SELECT id FROM participant WHERE token = 'tok-c-driver'), 'req-c-arrived'),
       ('visit-c-pick', 'boarded', (SELECT id FROM participant WHERE token = 'tok-c-driver'), 'req-c-boarded');
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-c-pick' AND version = 4;
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, confirmed_candidate_id FROM visit WHERE id = 'visit-c-pick';
COMMIT;

-- @step C-5 | 다른 장소 입력, 날씨에 따른 주차 자리 추천
-- @desc 미술관(시설 2)으로 가는 parking 방문을 같은 trip_id로 만들어요. 아래 추천 쿼리는 weather_json이 rain이면 실내·지붕·비 안 맞는 길이 많은 곳을 먼저 보여줘요.
-- @result 추천 1순위 미술관 지하 주차장 (rain 점수 3), 2순위 야외 주차장 (0). 지하로 결정하고 출발(departed), version 2
BEGIN;
INSERT INTO visit (id, trip_id, facility_id, mode, driver_device_id, weather_json, expires_at)
VALUES ('visit-c-park', 'trip-c-001', 2, 'parking', 'device-car-001',
        '{"condition":"rain","temp_c":15}', datetime('now', '+1 day'));
INSERT INTO participant (visit_id, role, token, display_name)
VALUES ('visit-c-park', 'driver', 'tok-c2-driver', '아빠');
COMMIT;

SELECT ap.id AS access_point_id, ap.name, ap.indoor, ap.has_roof, cn.walk_minutes, cn.covered,
       CASE WHEN json_extract(v.weather_json, '$.condition') = 'rain'
            THEN ap.indoor + ap.has_roof + COALESCE(cn.covered, 0) ELSE 0 END AS rain_score
  FROM visit v
  JOIN access_point ap  ON ap.facility_id = v.facility_id AND ap.type = 'parking' AND ap.active = 1
  LEFT JOIN connection cn ON cn.access_point_id = ap.id
 WHERE v.id = 'visit-c-park'
 ORDER BY rain_score DESC, cn.walk_minutes;

BEGIN;
INSERT INTO candidate (visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json)
VALUES
  ('visit-c-park', 'parking', 6, 4, 7, 1, 0.95, '["비","지하 주차장","로비까지 실내 연결"]'),
  ('visit-c-park', 'parking', 5, 4, 6, 2, 0.60, '["입구 가까움","비 맞음"]');
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-c-park', 'departed', (SELECT id FROM participant WHERE token = 'tok-c2-driver'), 'req-c2-departed');
UPDATE visit
   SET parking_candidate_id = (SELECT id FROM candidate WHERE visit_id = 'visit-c-park' AND access_point_id = 6),
       status = 'moving', current_stage = 'departed', version = version + 1
 WHERE id = 'visit-c-park' AND version = 1;
COMMIT;

-- @step C-6 | 주차 완료 (행복한 시간)
-- @desc 주차를 저장하고 방문을 닫아요(version 3). trip_id로 하루 외출 전체를 볼 수 있어요.
-- @result trip-c-001: visit-c-pick(pickup, ended) → visit-c-park(parking, ended, 미술관 지하 주차장)
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, request_id)
VALUES ('visit-c-park', 'parked', (SELECT id FROM participant WHERE token = 'tok-c2-driver'), 'req-c2-parked');
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-c-park' AND version = 2;
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, parking_candidate_id FROM visit WHERE id = 'visit-c-park';
COMMIT;

SELECT v.id, v.mode, f.name AS facility, v.status, v.version, ap.name AS parked_at
  FROM visit v
  JOIN facility f ON f.id = v.facility_id
  LEFT JOIN candidate c     ON c.id  = v.parking_candidate_id
  LEFT JOIN access_point ap ON ap.id = c.access_point_id
 WHERE v.trip_id = 'trip-c-001'
 ORDER BY v.created_at, v.rowid;

-- @end
-- 전체 확인: 모든 단계가 성공했으면 version이 A 6, B 6·3, C 5·3
SELECT id, trip_id, mode, status, version FROM visit WHERE id LIKE 'visit-%' AND id <> 'visit-demo-001' ORDER BY rowid;
