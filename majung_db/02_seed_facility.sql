-- =====================================================================
-- 시설 시드 데이터 (테스트용 시설 1곳)
-- 좌표는 임시값입니다. D 담당이 지도에서 실제 좌표로 교체하세요.
-- 실행: sqlite3 majung.db < 02_seed_facility.sql
-- =====================================================================

PRAGMA foreign_keys = ON;

INSERT INTO facility (id, name, address, lat, lng)
VALUES (1, '예시 쇼핑몰', '경기도 ○○시 ○○로 1', 37.5400, 127.2200);

-- 차가 가는 지점
INSERT INTO access_point
  (id, facility_id, type, name, lat, lng, has_roof, dropoff_allowed, indoor, elevator_nearby, stop_limit_min, vehicle_notes)
VALUES
  (1, 1, 'curb',    '서문 승하차 구역',   37.5402, 127.2190, 0, 1, 0, 0, 3,    '우회전 진입, 정차 3분'),
  (2, 1, 'curb',    '북문 승하차 구역',   37.5410, 127.2200, 1, 1, 0, 1, 5,    '지붕 있음, 엘리베이터 바로 옆'),
  (3, 1, 'curb',    '동문 출입구',        37.5401, 127.2215, 0, 0, 0, 0, NULL, '승하차 금지 구역 (후보 제외용)'),
  (4, 1, 'parking', '지하주차장 B2 입구', 37.5398, 127.2205, 1, 1, 1, 1, NULL, '유모차 전용 주차면 B2 23~28');

-- 사람이 기다리는 지점
INSERT INTO wait_spot (id, facility_id, name, floor, indoor, has_seating, description)
VALUES
  (1, 1, '1층 서문 로비',   '1F', 1, 1, '서문 안쪽, 의자 있음'),
  (2, 1, '1층 북문 로비',   '1F', 1, 1, '북문 안쪽, 비 안 맞음'),
  (3, 1, '2층 가족휴게실', '2F', 1, 1, '수유실·기저귀 교환대');

-- 연결 동선 (후보 = access_point + wait_spot + connection)
INSERT INTO connection
  (id, access_point_id, wait_spot_id, walk_minutes, stroller_ok, no_stairs, covered, description)
VALUES
  (1, 1, 1, 2, 1, 1, 0, '서문 로비 → 서문 구역, 야외 20m'),
  (2, 1, 3, 6, 1, 0, 0, '가족휴게실 → 계단 → 서문, 유모차는 우회 필요'),
  (3, 2, 2, 1, 1, 1, 1, '북문 로비 → 북문 구역, 지붕 연결'),
  (4, 2, 3, 4, 1, 1, 1, '가족휴게실 → 엘리베이터 → 북문, 실내 연결'),
  (5, 4, 3, 3, 1, 1, 1, '가족휴게실 → 엘리베이터 → B2 주차장');
