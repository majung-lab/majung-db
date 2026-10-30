-- =====================================================================
-- 테스트용 방문 1건: 시연 시나리오 #1~#6 상태
--   픽업 모드, 확정 장소 = 서문(A), 동승자가 비를 이유로 북문(B) 제안 중
-- 실행: sqlite3 majung.db < 03_demo_visit.sql  (02 실행 후)
-- =====================================================================

PRAGMA foreign_keys = ON;

INSERT INTO visit (id, facility_id, mode, status, current_stage, driver_device_id,
                   final_destination_json, weather_json, version, expires_at)
VALUES ('visit-demo-001', 1, 'pickup', 'created', 'created', 'device-car-001',
        '{"name":"집","lat":37.5000,"lng":127.1000}',
        '{"condition":"rain","temp_c":14,"checked_at":"2026-10-28T06:00:00Z"}',
        1, datetime('now', '+1 day'));

INSERT INTO participant (id, visit_id, role, token, display_name, conditions_json, current_wait_spot_id, status)
VALUES
  (1, 'visit-demo-001', 'driver',    'tok-driver-001',    '아빠', NULL, NULL, 'none'),
  (2, 'visit-demo-001', 'passenger', 'tok-passenger-001', '엄마',
      '{"stroller":true,"luggage":true,"avoid_stairs":true,"prefer_indoor":true}', 3, 'preparing');

-- 추천 결과: 북문 1순위, 서문 2순위, 동문 제외
INSERT INTO candidate (id, visit_id, purpose, access_point_id, wait_spot_id, connection_id, rank, score, reasons_json, excluded_reason)
VALUES
  (1, 'visit-demo-001', 'meet', 2, 2, 3, 1, 0.92, '["지붕 있음","유모차 실내 연결","도보 1분"]', NULL),
  (2, 'visit-demo-001', 'meet', 1, 1, 1, 2, 0.61, '["가까움"]', NULL),
  (3, 'visit-demo-001', 'meet', 3, NULL, NULL, NULL, NULL, NULL, '승하차 금지 구역');

-- 기존 약속은 서문(A, candidate 2)
UPDATE visit SET confirmed_candidate_id = 2 WHERE id = 'visit-demo-001';

-- 동승자가 북문(B, candidate 1)을 비 때문에 제안 (대기 중)
INSERT INTO proposal (id, visit_id, candidate_id, proposer_id, reason, status, base_version, request_id)
VALUES (1, 'visit-demo-001', 1, 2, 'rain', 'pending', 1, 'req-proposal-001');

-- 차량 위치 없음 상태의 갱신 1건 (실내 주차장 가정)
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-demo-001', NULL, NULL, NULL, NULL, 1);
