# 마중 DB

가족 픽업 앱 **마중**의 SQLite 데이터베이스입니다. 승하차 구역과 대기 로비 후보 추천, 동승자 링크 접속, 장소 변경 제안·수락, ETA 알림을 위한 데이터를 저장합니다.

- DB: SQLite / 서버: TypeScript + better-sqlite3
- 지금 상태와 남은 일: [majung_db_status.md](majung_db_status.md)
- 데이터 구조 그림: [majung_graph_model.png](majung_graph_model.png)
- 입문용 설명서 (열 설명, 시나리오 따라하기): [majung_db_guide.pdf](majung_db_guide.pdf)

## 폴더 구성

| 파일 | 내용 |
|---|---|
| majung_db/01_schema.sql | 테이블, 인덱스, 트리거, 뷰 |
| majung_db/02_seed_facility.sql | 시설 1 (예시 쇼핑몰, 좌표는 임시값) |
| majung_db/03_demo_visit.sql | 테스트 방문 1건 |
| majung_db/04_queries.sql | 화면별 핵심 쿼리 Q1~Q11 (서버 담당 참고용) |
| majung_db/05_seed_scenarios.sql | 시설 2 (예시 미술관) |
| majung_db/06_scenarios_abc.sql | 기획서 시나리오 A·B·C 단계별 실행 |
| majung_db/README.md | 설계 요점 |

## DB 만들기

majung.db는 저장소에 올리지 않습니다. SQL 파일이 원본이고, 아래 명령으로 언제든 다시 만들 수 있습니다. 저장소 폴더에서 실행합니다.

```powershell
sqlite3 majung.db ".read majung_db/01_schema.sql" ".read majung_db/02_seed_facility.sql" ".read majung_db/03_demo_visit.sql"
sqlite3 majung.db ".read majung_db/05_seed_scenarios.sql"
```

시나리오 A·B·C까지 돌려 보려면 이어서 `sqlite3 majung.db ".read majung_db/06_scenarios_abc.sql"` 을 실행합니다.

## 서버에서 쓸 때 꼭 지킬 것

1. 연결 직후 `PRAGMA foreign_keys = ON` 실행 (SQLite 기본값은 꺼져 있음)
2. visit을 고칠 때는 `WHERE version = ?` 로 확인하고, 바뀐 줄이 0이면 409 응답
3. 방문은 확정 장소·주차 자리를 비워서 만들고, 후보 저장 뒤 UPDATE로 채우기

자세한 규칙은 [majung_db_status.md](majung_db_status.md)의 "서버 연결 규칙"을 참고하세요.
