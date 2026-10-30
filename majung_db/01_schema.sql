-- =====================================================================
-- 마중 DB 스키마 (SQLite)
-- 실행: sqlite3 majung.db < 01_schema.sql
-- 규칙
--   * 불리언은 INTEGER 0/1
--   * 시각은 TEXT (ISO 8601, UTC) — datetime('now')
--   * JSON은 TEXT 컬럼에 저장 (SQLite json1 함수로 조회 가능)
--   * "현재 상태"는 visit 컬럼, "이력"은 *_event / vehicle_update
-- =====================================================================

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;

-- ---------------------------------------------------------------------
-- A. 시설 데이터 (D 담당이 JSON으로 채움, 거의 변하지 않음)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS facility (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name        TEXT    NOT NULL,
  address     TEXT,
  lat         REAL    NOT NULL,
  lng         REAL    NOT NULL,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- 차가 실제로 가는 지점 (승하차 구역, 주차장)
CREATE TABLE IF NOT EXISTS access_point (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  facility_id      INTEGER NOT NULL REFERENCES facility(id) ON DELETE CASCADE,
  type             TEXT    NOT NULL CHECK (type IN ('curb', 'parking')),  -- curb=승하차 구역
  name             TEXT    NOT NULL,
  lat              REAL    NOT NULL,   -- NaviHelper requestRoute에 넣는 좌표
  lng              REAL    NOT NULL,
  has_roof         INTEGER NOT NULL DEFAULT 0,
  dropoff_allowed  INTEGER NOT NULL DEFAULT 1,  -- 0이면 후보에서 제외
  indoor           INTEGER NOT NULL DEFAULT 0,
  elevator_nearby  INTEGER NOT NULL DEFAULT 0,
  stop_limit_min   INTEGER,                     -- 정차 제한(분), NULL=제한 없음
  vehicle_notes    TEXT,                        -- "진입은 우회전만 가능" 등
  active           INTEGER NOT NULL DEFAULT 1
);

-- 사람이 기다리는 지점 (로비, 휴게실)
CREATE TABLE IF NOT EXISTS wait_spot (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  facility_id  INTEGER NOT NULL REFERENCES facility(id) ON DELETE CASCADE,
  name         TEXT    NOT NULL,
  floor        TEXT,
  indoor       INTEGER NOT NULL DEFAULT 1,
  has_seating  INTEGER NOT NULL DEFAULT 0,
  description  TEXT,
  active       INTEGER NOT NULL DEFAULT 1
);

-- 두 지점의 연결 동선 (후보 = access_point + wait_spot + connection)
CREATE TABLE IF NOT EXISTS connection (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  access_point_id  INTEGER NOT NULL REFERENCES access_point(id) ON DELETE CASCADE,
  wait_spot_id     INTEGER NOT NULL REFERENCES wait_spot(id)    ON DELETE CASCADE,
  walk_minutes     INTEGER NOT NULL,            -- 대기 지점 → 승하차 구역 도보 시간
  stroller_ok      INTEGER NOT NULL DEFAULT 1,
  no_stairs        INTEGER NOT NULL DEFAULT 1,
  covered          INTEGER NOT NULL DEFAULT 0,  -- 비 안 맞고 이동 가능
  description      TEXT,
  UNIQUE (access_point_id, wait_spot_id)
);

-- ---------------------------------------------------------------------
-- B. 방문 데이터 (앱이 읽고 씀)
-- ---------------------------------------------------------------------

-- 한 번의 외출 (시나리오 B: 내려주기 → 다시 만나기, C: 픽업 → 다른 장소 주차)
CREATE TABLE IF NOT EXISTS trip (
  id                TEXT    PRIMARY KEY,                       -- UUID (서버 생성)
  driver_device_id  TEXT    NOT NULL,
  share_token       TEXT    UNIQUE,                            -- 외출 전체 공유 링크, 열면 진행 중인 방문을 보여줌 (P1)
  created_at        TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS visit (
  id                      TEXT    PRIMARY KEY,                 -- UUID (서버 생성)
  trip_id                 TEXT    REFERENCES trip(id),         -- 같은 외출 묶음, 방문 하나뿐이면 NULL
  facility_id             INTEGER NOT NULL REFERENCES facility(id),
  mode                    TEXT    NOT NULL CHECK (mode IN ('pickup', 'dropoff', 'parking')),  -- 흐름도 C03: 픽업하기/내려주기/그냥가기
  status                  TEXT    NOT NULL DEFAULT 'created'
                          CHECK (status IN ('created', 'moving', 'arrived', 'boarded', 'ended', 'cancelled')),
  current_stage           TEXT    NOT NULL DEFAULT 'created'
                          CHECK (current_stage IN ('created', 'departed', 'dropoff_done', 'parked', 'pickup_started',
                                                   'arrival_imminent', 'arrived', 'boarded', 'ended', 'cancelled')),
  confirmed_candidate_id  INTEGER REFERENCES candidate(id),    -- 만남/하차 지점, purpose = 'meet' 후보
  parking_candidate_id    INTEGER REFERENCES candidate(id),    -- 주차 지점, purpose = 'parking' 후보 (모든 mode 가능)
  driver_device_id        TEXT    NOT NULL,                    -- P0는 로그인 없음, 차량 앱이 생성한 ID
  final_destination_json  TEXT,                                -- {"name":"집","lat":..,"lng":..}
  weather_json            TEXT,                                -- 추천 시점 날씨 스냅샷
  -- 차량 최신 상태 (W01 방문 카드가 바로 읽는 값, 이력은 vehicle_update)
  last_lat                REAL,
  last_lng                REAL,
  last_eta_sec            INTEGER,
  last_nav_result         TEXT    CHECK (last_nav_result IN ('set', 'failed') OR last_nav_result IS NULL),
  last_vehicle_at         TEXT,
  -- 동시성 제어: 모든 쓰기는 "내가 본 version"을 보내고, 다르면 거부
  version                 INTEGER NOT NULL DEFAULT 1,
  expires_at              TEXT    NOT NULL,
  created_at              TEXT    NOT NULL DEFAULT (datetime('now')),
  updated_at              TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS participant (
  id                    INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id              TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  role                  TEXT    NOT NULL CHECK (role IN ('driver', 'passenger')),
  token                 TEXT    NOT NULL UNIQUE,              -- 링크/QR에 들어가는 값
  display_name          TEXT,
  conditions_json       TEXT,    -- {"stroller":true,"luggage":true,"avoid_stairs":true,"prefer_indoor":true}
  current_wait_spot_id  INTEGER REFERENCES wait_spot(id),     -- 동승자가 고른 "지금 가까운 지점"
  status                TEXT    NOT NULL DEFAULT 'none'
                        CHECK (status IN ('none', 'preparing', 'moving_to_lobby', 'at_lobby')),
  expected_ready_at     TEXT,                                 -- 준비 예정 시간 (표시용, 협의 아님)
  joined_at             TEXT    NOT NULL DEFAULT (datetime('now')),
  last_seen_at          TEXT
);

-- 이 방문에서 추천/제외된 후보 (시설 데이터가 바뀌어도 과거 방문이 안 깨지도록 방문마다 복사)
CREATE TABLE IF NOT EXISTS candidate (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id         TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  purpose          TEXT    NOT NULL CHECK (purpose IN ('meet', 'parking')),  -- meet=만남·하차 지점, parking=주차
  access_point_id  INTEGER NOT NULL REFERENCES access_point(id),
  wait_spot_id     INTEGER REFERENCES wait_spot(id),          -- 주차 후보면 NULL 가능
  connection_id    INTEGER REFERENCES connection(id),
  rank             INTEGER,                                   -- 1=최우선 추천, NULL=제외 (purpose별 순위)
  score            REAL,
  reasons_json     TEXT,                                      -- ["유모차 통로 연결","지붕 있음"]
  excluded_reason  TEXT,                                      -- NULL이면 추천 후보
  created_at       TEXT    NOT NULL DEFAULT (datetime('now')),
  -- 추천된 만남 후보는 기다릴 곳이 있어야 함
  CHECK (purpose = 'parking' OR wait_spot_id IS NOT NULL OR excluded_reason IS NOT NULL)
);

-- 장소 변경 제안 (운전자·동승자 모두 가능, 방문당 대기 중 제안은 1개)
CREATE TABLE IF NOT EXISTS proposal (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id       TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  candidate_id   INTEGER NOT NULL REFERENCES candidate(id),
  proposer_id    INTEGER NOT NULL REFERENCES participant(id),
  reason         TEXT    CHECK (reason IN ('rain', 'closer', 'stroller', 'crowded', 'other') OR reason IS NULL),
  reason_text    TEXT,
  status         TEXT    NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
  base_version   INTEGER NOT NULL,                            -- 제안 당시 visit.version
  request_id     TEXT    NOT NULL UNIQUE,                     -- 중복 클릭 방지
  responder_id   INTEGER REFERENCES participant(id),
  responded_via  TEXT    CHECK (responded_via IN ('touch', 'voice') OR responded_via IS NULL),  -- 음성 수락 (P1)
  created_at     TEXT    NOT NULL DEFAULT (datetime('now')),
  responded_at   TEXT
);

-- 상태 변경 이력
CREATE TABLE IF NOT EXISTS stage_event (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id    TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  stage       TEXT    NOT NULL
              CHECK (stage IN ('departed', 'dropoff_done', 'parked', 'pickup_started', 'arrival_imminent',
                               'arrived', 'boarded', 'ended', 'cancelled')),
  actor_id    INTEGER REFERENCES participant(id),
  source      TEXT    NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'sensor', 'system')),
  request_id  TEXT    NOT NULL UNIQUE,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- 차량 위치·ETA·내비 결과 이력 (lat/lng NULL = 위치 없음)
CREATE TABLE IF NOT EXISTS vehicle_update (
  id                          INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id                    TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  lat                         REAL,
  lng                         REAL,
  eta_sec                     INTEGER,
  nav_result                  TEXT    CHECK (nav_result IN ('set', 'failed') OR nav_result IS NULL),
  nav_target_access_point_id  INTEGER REFERENCES access_point(id),
  recorded_at                 TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ---------------------------------------------------------------------
-- C. 기록·평가 (흐름도 C08 장소 평가, C09 목적지 기록)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS place_rating (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  visit_id      TEXT    NOT NULL REFERENCES visit(id) ON DELETE CASCADE,
  candidate_id  INTEGER NOT NULL REFERENCES candidate(id),
  rating        INTEGER NOT NULL CHECK (rating BETWEEN 1 AND 5),
  tags_json     TEXT,                                          -- ["유모차 편함","비 맞음"]
  comment       TEXT,
  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS destination_history (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  driver_device_id  TEXT    NOT NULL,
  facility_id       INTEGER NOT NULL REFERENCES facility(id),
  mode              TEXT    NOT NULL,
  last_candidate_id INTEGER REFERENCES candidate(id),
  visited_at        TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ---------------------------------------------------------------------
-- D. 인덱스·제약
-- ---------------------------------------------------------------------

-- 방문당 운전자 1명
CREATE UNIQUE INDEX IF NOT EXISTS ux_participant_driver
  ON participant(visit_id) WHERE role = 'driver';

-- 방문당 대기 중 제안 1개 (양방향 동시 제안 충돌 방지)
CREATE UNIQUE INDEX IF NOT EXISTS ux_proposal_pending
  ON proposal(visit_id) WHERE status = 'pending';

-- 방문·용도별 순위 중복 금지 (만남 1순위와 주차 1순위는 각각 하나)
CREATE UNIQUE INDEX IF NOT EXISTS ux_candidate_rank
  ON candidate(visit_id, purpose, rank) WHERE rank IS NOT NULL;

CREATE INDEX IF NOT EXISTS ix_participant_visit     ON participant(visit_id);
CREATE INDEX IF NOT EXISTS ix_visit_trip            ON visit(trip_id, created_at);
CREATE INDEX IF NOT EXISTS ix_proposal_visit_status ON proposal(visit_id, status);
CREATE INDEX IF NOT EXISTS ix_stage_event_visit     ON stage_event(visit_id, created_at);
CREATE INDEX IF NOT EXISTS ix_vehicle_update_visit  ON vehicle_update(visit_id, recorded_at);
CREATE INDEX IF NOT EXISTS ix_visit_driver          ON visit(driver_device_id, created_at);
CREATE INDEX IF NOT EXISTS ix_visit_expires         ON visit(expires_at);
CREATE INDEX IF NOT EXISTS ix_access_point_facility ON access_point(facility_id, type, active);
CREATE INDEX IF NOT EXISTS ix_connection_ap         ON connection(access_point_id);

-- visit.updated_at 자동 갱신 (version은 앱이 WHERE version=? 패턴으로 직접 올림)
CREATE TRIGGER IF NOT EXISTS trg_visit_updated_at
AFTER UPDATE ON visit
FOR EACH ROW WHEN NEW.updated_at = OLD.updated_at
BEGIN
  UPDATE visit SET updated_at = datetime('now') WHERE id = NEW.id;
END;

-- 확정 장소는 "이 방문의 meet 후보", 주차 자리는 "이 방문의 parking 후보"만 허용
-- (다른 테이블을 봐야 하는 규칙이라 CHECK로는 못 막음)
-- INSERT 시점엔 이 방문의 후보가 아직 없으므로, 사실상 두 열은 NULL로 만들고 나중에 UPDATE로 채움
CREATE TRIGGER IF NOT EXISTS trg_visit_candidate_insert
BEFORE INSERT ON visit
FOR EACH ROW
BEGIN
  SELECT RAISE(ABORT, 'confirmed_candidate_id에는 이 방문의 meet 후보만 넣을 수 있어요')
   WHERE NEW.confirmed_candidate_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM candidate
                      WHERE id = NEW.confirmed_candidate_id AND visit_id = NEW.id AND purpose = 'meet');
  SELECT RAISE(ABORT, 'parking_candidate_id에는 이 방문의 parking 후보만 넣을 수 있어요')
   WHERE NEW.parking_candidate_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM candidate
                      WHERE id = NEW.parking_candidate_id AND visit_id = NEW.id AND purpose = 'parking');
END;

CREATE TRIGGER IF NOT EXISTS trg_visit_candidate_update
BEFORE UPDATE OF confirmed_candidate_id, parking_candidate_id ON visit
FOR EACH ROW
BEGIN
  SELECT RAISE(ABORT, 'confirmed_candidate_id에는 이 방문의 meet 후보만 넣을 수 있어요')
   WHERE NEW.confirmed_candidate_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM candidate
                      WHERE id = NEW.confirmed_candidate_id AND visit_id = NEW.id AND purpose = 'meet');
  SELECT RAISE(ABORT, 'parking_candidate_id에는 이 방문의 parking 후보만 넣을 수 있어요')
   WHERE NEW.parking_candidate_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM candidate
                      WHERE id = NEW.parking_candidate_id AND visit_id = NEW.id AND purpose = 'parking');
END;

-- ---------------------------------------------------------------------
-- E. 뷰: W01 방문 카드 / C06 차량 화면이 한 번에 읽는 형태
-- ---------------------------------------------------------------------

CREATE VIEW IF NOT EXISTS v_visit_card AS
SELECT
  v.id                      AS visit_id,
  v.trip_id,
  v.mode,
  v.status,
  v.current_stage,
  v.version,
  v.expires_at,
  f.name                    AS facility_name,
  c.id                      AS candidate_id,
  ap.name                   AS access_point_name,   -- 운전자 화면: 차가 가는 곳
  ap.lat                    AS access_lat,
  ap.lng                    AS access_lng,
  ap.has_roof,
  ws.name                   AS wait_spot_name,      -- 동승자 화면: 기다리는 곳
  ws.floor                  AS wait_spot_floor,
  cn.walk_minutes,
  cn.covered                AS walk_covered,
  v.last_lat,
  v.last_lng,
  v.last_eta_sec,
  v.last_nav_result,
  v.last_vehicle_at,
  p.status                  AS passenger_status,
  p.expected_ready_at       AS passenger_expected_ready_at,
  (SELECT pr.id FROM proposal pr
     WHERE pr.visit_id = v.id AND pr.status = 'pending') AS pending_proposal_id
FROM visit v
JOIN facility f           ON f.id  = v.facility_id
LEFT JOIN candidate c     ON c.id  = v.confirmed_candidate_id
LEFT JOIN access_point ap ON ap.id = c.access_point_id
LEFT JOIN wait_spot ws    ON ws.id = c.wait_spot_id
LEFT JOIN connection cn   ON cn.id = c.connection_id
LEFT JOIN participant p   ON p.visit_id = v.id AND p.role = 'passenger';
