# 마중 DB (SQLite)

## 실행 순서
```bash
sqlite3 majung.db < 01_schema.sql         # 테이블·인덱스·뷰
sqlite3 majung.db < 02_seed_facility.sql  # 시설 1곳 (좌표는 임시값)
sqlite3 majung.db < 03_demo_visit.sql     # 테스트 방문 1건 (선택)
sqlite3 majung.db < 05_seed_scenarios.sql # 시나리오 A·B·C용 시설 2 (예시 미술관)
sqlite3 majung.db < 06_scenarios_abc.sql  # 시나리오 A·B·C 단계별 실행 (선택)
```
`04_queries.sql`은 화면별 핵심 쿼리 모음 (API 담당 참고용).
PowerShell은 `<`를 지원하지 않으니 `sqlite3 majung.db ".read majung_db/01_schema.sql"`처럼 실행.

## 설계 요점
- **추천 후보 = access_point + wait_spot + connection** — 운전자는 access_point, 동승자는 wait_spot을 봄
- **후보 용도**: `candidate.purpose` = `meet`(만남·하차) / `parking`(주차), 순위는 용도별 (`ux_candidate_rank`)
- **후보 연결 트리거**: `visit.confirmed_candidate_id`는 이 방문의 meet 후보, `parking_candidate_id`는 이 방문의 parking 후보만 (`trg_visit_candidate_insert` / `_update`). 방문을 만들 땐 두 열을 NULL로 두고 후보 저장 후 UPDATE
- **현재 상태는 `visit` 컬럼, 이력은 `stage_event` / `vehicle_update`**
- **동시성**: 모든 쓰기는 `WHERE version = :본값` → changes()=0이면 409
- **중복 방지**: `proposal.request_id`, `stage_event.request_id` UNIQUE
- **제안 1개 규칙**: `ux_proposal_pending` 부분 유니크 인덱스
- **링크**: `participant.token` UNIQUE, `visit.expires_at`로 만료
- **로그인 없음(P0)**: 운전자는 `driver_device_id`로 구분
- **외출 묶음(시나리오 B·C)**: `trip` 테이블 + `visit.trip_id` 외래키, `trip.share_token` 링크 하나로 진행 중인 방문을 봄 (Q11)
- **단계**: 함께 출발은 `departed`, 취소는 `cancelled` (visit.current_stage와 stage_event 둘 다)
- `v_visit_card` 뷰 하나로 W01 방문 카드와 C06 차량 화면을 읽음

## TypeScript에서 쓰기
- 드라이버: `better-sqlite3` (동기, 트랜잭션 간단) 권장
- 연결 직후 `PRAGMA foreign_keys = ON` 실행 필수 (SQLite는 기본 OFF)
- 나중에 PostgreSQL로 옮길 땐 `INTEGER 0/1 → BOOLEAN`, `TEXT 시각 → TIMESTAMPTZ`, `AUTOINCREMENT → SERIAL`만 바꾸면 됨
