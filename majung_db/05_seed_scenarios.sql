-- =====================================================================
-- 시나리오 A·B·C용 추가 데이터 (01, 02 실행 후)
--   * 시설 2: 시나리오 C (5)에서 같이 놀러 가는 "다른 장소"
-- 좌표는 임시값입니다.
-- 실행: sqlite3 majung.db ".read majung_db/05_seed_scenarios.sql"
-- =====================================================================

PRAGMA foreign_keys = ON;

INSERT INTO facility (id, name, address, lat, lng)
VALUES (2, '예시 미술관', '경기도 ○○시 ○○로 20', 37.5500, 127.2400);

-- 주차 후보 2곳: 맑으면 야외가 가깝고, 비 오면 지하가 낫다
INSERT INTO access_point
  (id, facility_id, type, name, lat, lng, has_roof, dropoff_allowed, indoor, elevator_nearby, stop_limit_min, vehicle_notes)
VALUES
  (5, 2, 'parking', '미술관 야외 주차장', 37.5502, 127.2395, 0, 1, 0, 0, NULL, '입구 바로 앞, 지붕 없음'),
  (6, 2, 'parking', '미술관 지하 주차장', 37.5498, 127.2405, 1, 1, 1, 1, NULL, 'B1, 엘리베이터로 로비 연결');

INSERT INTO wait_spot (id, facility_id, name, floor, indoor, has_seating, description)
VALUES (4, 2, '미술관 1층 로비', '1F', 1, 1, '매표소 앞');

INSERT INTO connection
  (id, access_point_id, wait_spot_id, walk_minutes, stroller_ok, no_stairs, covered, description)
VALUES
  (6, 5, 4, 1, 1, 1, 0, '야외 주차장 → 정문 → 로비, 야외 30m'),
  (7, 6, 4, 3, 1, 1, 1, '지하 주차장 → 엘리베이터 → 로비, 실내 연결');
