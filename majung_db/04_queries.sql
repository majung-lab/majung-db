-- =====================================================================
-- 화면별 핵심 쿼리 (API 담당 참고용)
-- :visit_id, :version 같은 값은 서버 코드에서 바인딩
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. W01 방문 카드 / C06 차량 화면 (한 번에 읽기)
-- ---------------------------------------------------------------------
SELECT * FROM v_visit_card WHERE visit_id = 'visit-demo-001';

-- ---------------------------------------------------------------------
-- Q2. C04 후보 추천용 원본 조회
--     조건: 승하차 허용, 유모차 가능, 계단 없음 → 지붕·실내 우선, 도보 짧은 순
-- ---------------------------------------------------------------------
SELECT ap.id AS access_point_id, ap.name AS access_point, ap.has_roof,
       ws.id AS wait_spot_id, ws.name AS wait_spot,
       cn.id AS connection_id, cn.walk_minutes, cn.covered
FROM connection cn
JOIN access_point ap ON ap.id = cn.access_point_id
JOIN wait_spot ws    ON ws.id = cn.wait_spot_id
WHERE ap.facility_id = 1
  AND ap.type = 'curb' AND ap.active = 1 AND ap.dropoff_allowed = 1
  AND cn.stroller_ok = 1 AND cn.no_stairs = 1
ORDER BY ap.has_roof DESC, cn.covered DESC, cn.walk_minutes ASC;

-- 제외 후보 (추천 화면에 "제외 이유"로 표시)
SELECT ap.id, ap.name, '승하차 금지 구역' AS excluded_reason
FROM access_point ap
WHERE ap.facility_id = 1 AND ap.type = 'curb' AND ap.dropoff_allowed = 0;

-- ---------------------------------------------------------------------
-- Q3. 대기 중 제안 조회 (W02 팝업 / 차량 화면 알림)
-- ---------------------------------------------------------------------
SELECT pr.id, pr.reason, pr.created_at, p.role AS proposer_role, p.display_name AS proposer,
       ap.name AS proposed_access_point, ws.name AS proposed_wait_spot
FROM proposal pr
JOIN participant p    ON p.id  = pr.proposer_id
JOIN candidate c      ON c.id  = pr.candidate_id
JOIN access_point ap  ON ap.id = c.access_point_id
LEFT JOIN wait_spot ws ON ws.id = c.wait_spot_id
WHERE pr.visit_id = 'visit-demo-001' AND pr.status = 'pending';

-- ---------------------------------------------------------------------
-- Q4. 제안 수락 (트랜잭션 + 버전 검증)
--     1) visit.version이 클라이언트가 본 값(:version)과 같을 때만 반영
--     2) changes() = 0 이면 충돌 → 409 응답, 롤백
-- ---------------------------------------------------------------------
BEGIN;
UPDATE visit
   SET confirmed_candidate_id = (SELECT candidate_id FROM proposal WHERE id = 1),
       version = version + 1
 WHERE id = 'visit-demo-001' AND version = 1;          -- :version
-- 서버: if (changes() == 0) ROLLBACK
UPDATE proposal
   SET status = 'accepted', responder_id = 1, responded_at = datetime('now')
 WHERE id = 1 AND status = 'pending';
COMMIT;

-- 거절은 proposal만 바꾸고 visit은 그대로 (기존 약속 유지)
-- UPDATE proposal SET status='rejected', responder_id=1, responded_at=datetime('now')
--  WHERE id = 1 AND status = 'pending';

-- ---------------------------------------------------------------------
-- Q5. 상태 변경 (예: 픽업 시작) — request_id로 중복 방지
-- ---------------------------------------------------------------------
BEGIN;
INSERT INTO stage_event (visit_id, stage, actor_id, source, request_id)
VALUES ('visit-demo-001', 'pickup_started', 1, 'manual', 'req-stage-001');
-- UNIQUE 위반이면 이미 처리된 요청 → 현재 상태를 그대로 응답
UPDATE visit
   SET current_stage = 'pickup_started', status = 'moving', version = version + 1
 WHERE id = 'visit-demo-001' AND version = 2;          -- :version
COMMIT;

-- 도어 센서가 제안한 하차 완료는 source='sensor'로 구분
-- INSERT INTO stage_event (...) VALUES (..., 'dropoff_done', 1, 'sensor', 'req-stage-002');

-- ---------------------------------------------------------------------
-- Q6. 차량 위치·ETA 갱신 (이력 + 최신값 동시 기록)
-- ---------------------------------------------------------------------
BEGIN;
INSERT INTO vehicle_update (visit_id, lat, lng, eta_sec, nav_result, nav_target_access_point_id)
VALUES ('visit-demo-001', 37.5405, 127.2195, 240, 'set', 2);
UPDATE visit
   SET last_lat = 37.5405, last_lng = 127.2195, last_eta_sec = 240,
       last_nav_result = 'set', last_vehicle_at = datetime('now')
 WHERE id = 'visit-demo-001';
COMMIT;

-- ---------------------------------------------------------------------
-- Q7. "이제 나오세요" 판정: ETA <= 도보 시간
-- ---------------------------------------------------------------------
SELECT visit_id,
       last_eta_sec, walk_minutes * 60 AS walk_sec,
       CASE WHEN last_eta_sec IS NULL THEN 'no_location'
            WHEN last_eta_sec <= walk_minutes * 60 THEN 'go_now'
            ELSE 'wait' END AS passenger_instruction
FROM v_visit_card WHERE visit_id = 'visit-demo-001';

-- ---------------------------------------------------------------------
-- Q8. 동승자 준비 상태 갱신
-- ---------------------------------------------------------------------
UPDATE participant
   SET status = 'at_lobby', last_seen_at = datetime('now')
 WHERE token = 'tok-passenger-001';

-- ---------------------------------------------------------------------
-- Q9. 링크 접속 검증 (토큰 → 방문, 만료·종료 확인)
-- ---------------------------------------------------------------------
SELECT p.role, v.id AS visit_id, v.status,
       CASE WHEN v.expires_at < datetime('now') OR v.status IN ('ended','cancelled')
            THEN 1 ELSE 0 END AS is_closed
FROM participant p JOIN visit v ON v.id = p.visit_id
WHERE p.token = 'tok-passenger-001';

-- ---------------------------------------------------------------------
-- Q10. 방문 종료 + 기록 (탑승 완료 후)
-- ---------------------------------------------------------------------
BEGIN;
UPDATE visit SET status = 'ended', current_stage = 'ended', version = version + 1
 WHERE id = 'visit-demo-001';
INSERT INTO destination_history (driver_device_id, facility_id, mode, last_candidate_id)
SELECT driver_device_id, facility_id, mode, confirmed_candidate_id
  FROM visit WHERE id = 'visit-demo-001';
COMMIT;

-- ---------------------------------------------------------------------
-- Q11. 외출 공유 링크 (trip.share_token → 지금 진행 중인 방문)
--      시나리오 B처럼 방문이 바뀌어도 동승자는 링크 하나로 계속 봄
--      (데이터는 06_scenarios_abc.sql에서 만들어짐)
-- ---------------------------------------------------------------------
SELECT t.id AS trip_id, v.id AS visit_id, v.mode, v.status
  FROM trip t
  JOIN visit v ON v.trip_id = t.id
 WHERE t.share_token = 'tok-trip-b'
   AND v.status NOT IN ('ended', 'cancelled')
 ORDER BY v.created_at DESC, v.rowid DESC
 LIMIT 1;
