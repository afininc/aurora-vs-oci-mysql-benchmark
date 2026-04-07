# Aurora MySQL vs OCI MySQL MDS 벤치마크: Enterprise Thread Pool 가설 검증

## TL;DR

> **Quick Summary**: Aurora MySQL과 OCI MySQL MDS의 Enterprise Thread Pool 성능 차이를 검증하기 위한 Terraform 인프라 + 벤치마크 스크립트 + 실행 계획. 핵심은 `thread_pool_max_transactions_limit` 유무에 따른 스파이크 트래픽 방어 능력 비교.
> 
> **Deliverables**:
> - Terraform 모듈 2개 (AWS Aurora + OCI MySQL MDS)
> - Sysbench 벤치마크 스크립트 (표준 oltp + 커스텀 티켓팅 Lua)
> - HammerDB TPC-C 자동화 스크립트
> - MySQL 모니터링 수집 스크립트 (Python)
> - 결과 시각화 스크립트 (matplotlib)
> - 벤치마크 오케스트레이션 러너
> 
> **Estimated Effort**: Large
> **Parallel Execution**: YES - 4 waves
> **Critical Path**: T1→T3→T5→T8→T10→T12→T14→T15→T16→F1-F4

---

## Context

### Original Request
Aurora MySQL vs OCI MySQL MDS의 Enterprise Thread Pool 가설 검증을 위한 인프라 환경(Terraform) 및 벤치마크 수행 계획 수립. 티켓팅 워크로드에서 OCI의 `thread_pool_max_transactions_limit`이 Aurora 대비 TPS cliff를 방어한다는 가설을 Sysbench + HammerDB로 검증.

### Interview Summary
**Key Discussions**:
- 인스턴스 대칭: vCPU 수 기준 — Aurora db.r6g.4xlarge (16 vCPU, 128GB) vs OCI 8 OCPU (16 vCPU, 128GB)
- 벤치마크 도구: Sysbench (primary) + HammerDB TPC-C (secondary)
- RDS Proxy 미포함 — 순수 엔진 레벨 비교
- Terraform = 인프라만. 벤치마크 도구 설치/설정은 SSH 접속하여 직접 수행
- 결과물: 기술 보고서 + matplotlib 차트

**Research Findings**:
- AWS Aurora: `aws_rds_cluster` + `aws_rds_cluster_instance`, parameter group family `aurora-mysql8.0`
- OCI MySQL: `oci_mysql_mysql_db_system` + `oci_mysql_mysql_configuration`, thread pool 변수 공식 지원
- OCI config는 immutable — 생성 시 thread pool 값 확정 필요
- 4096 threads 시 클라이언트 OS 튜닝 필수 (ulimit, somaxconn, ip_local_port_range)

### Metis Review
**Identified Gaps** (addressed):
- Aurora single-writer만 사용 (reader 없음) → 플랜에 반영
- `max_connections`, `innodb_buffer_pool_size` 양쪽 동일 설정 → 파라미터 그룹에 명시
- OCI config immutability → 별도 리소스로 분리, 생성 시 확정
- 클라이언트 병목 가능성 → OS 튜닝 스크립트 포함
- 반복 측정 3회 + 워밍업 60초 제외 → 오케스트레이션 스크립트에 반영
- 크레덴셜 하드코딩 금지 → variables + sensitive

---

## Work Objectives

### Core Objective
동일 스펙(16 vCPU, 128GB) 환경에서 Aurora MySQL과 OCI MySQL MDS의 스파이크 트래픽(32→4096 threads) 처리 능력을 비교하여, Enterprise Thread Pool의 `thread_pool_max_transactions_limit`이 TPS cliff를 방어하는지 검증한다.

### Concrete Deliverables
- `terraform/aws/` — AWS VPC + Aurora MySQL + EC2 벤치마크 클라이언트
- `terraform/oci/` — OCI VCN + MySQL MDS (thread pool 설정) + Compute 벤치마크 클라이언트
- `scripts/sysbench/` — 표준 oltp 스파이크 러너 + 커스텀 티켓팅 Lua
- `scripts/hammerdb/` — TPC-C 자동화 Tcl 스크립트
- `scripts/monitoring/` — Python MySQL 메트릭 수집기
- `scripts/visualization/` — matplotlib 차트 생성기
- `scripts/run_benchmark.sh` — 전체 벤치마크 오케스트레이션

### Definition of Done
- [ ] `terraform validate` + `terraform plan` 양쪽 모듈 모두 에러 0
- [ ] 벤치마크 클라이언트에서 양쪽 DB로 `mysql -h <endpoint> -e "SELECT 1"` 성공
- [ ] OCI MySQL `SHOW VARIABLES LIKE 'thread_pool%'` 설정값 확인
- [ ] Sysbench 32→4096 threads 단계별 실행 완료 (양쪽)
- [ ] HammerDB TPC-C 실행 완료 (양쪽)
- [ ] TPS cliff 비교 차트 PNG 생성

### Must Have
- 양쪽 `max_connections = 5000`, `innodb_buffer_pool_size = 96G` 동일
- OCI thread pool: `thread_pool_size=16`, `thread_pool_max_transactions_limit=512`, `thread_pool_algorithm=1`
- Sysbench 단계별 스파이크: 32, 64, 128, 256, 512, 1024, 2048, 4096 threads
- Pareto 분포 hot row 경합 테스트
- 각 단계 최소 3회 반복, 워밍업 60초 제외
- `--report-interval=5` 단위 TPS/latency 시계열 수집
- 모니터링: `Threads_running`, `Threads_connected`, `Innodb_row_lock_waits`, `Innodb_row_lock_time`

### Must NOT Have (Guardrails)
- Aurora Serverless v2 사용 금지 — provisioned만
- Aurora Multi-AZ / reader replica 금지 — single-writer만
- RDS Proxy 포함 금지
- Terraform에 크레덴셜 하드코딩 금지
- Terraform으로 벤치마크 도구 설치 금지 (인프라만)
- Grafana/모니터링 인프라 구축 금지 (post-hoc 분석만)
- 인스턴스 사이즈 스윕 금지 (16 vCPU/128GB 고정)

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** - ALL verification is agent-executed. No exceptions.

### Test Decision
- **Infrastructure exists**: NO (greenfield)
- **Automated tests**: Terraform validate/plan + shellcheck + py_compile
- **Framework**: terraform CLI + shellcheck + python3

### QA Policy
Every task MUST include agent-executed QA scenarios.
Evidence saved to `.sisyphus/evidence/task-{N}-{scenario-slug}.{ext}`.

- **Terraform**: `terraform validate` + `terraform plan` — exit code 0
- **Shell scripts**: `shellcheck` + `bash -n` — exit code 0
- **Python scripts**: `python3 -m py_compile` — exit code 0
- **Lua scripts**: `luac -p` syntax check
- **SSH 작업**: 명령 실행 후 출력 캡처로 검증

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Foundation — shared configs + networking):
├── Task 1: AWS Terraform — providers, variables, VPC/subnets/SG [quick]
├── Task 2: OCI Terraform — providers, variables, VCN/subnets/NSG [quick]
└── Task 3: Sysbench 커스텀 Lua 티켓팅 스크립트 [deep]

Wave 2 (DB + Client + Scripts — after Wave 1):
├── Task 4: AWS Terraform — Aurora MySQL cluster + parameter groups [quick]
├── Task 5: OCI Terraform — MySQL MDS + thread pool configuration [quick]
├── Task 6: AWS Terraform — EC2 벤치마크 클라이언트 + outputs [quick]
├── Task 7: OCI Terraform — Compute 벤치마크 클라이언트 + outputs [quick]
├── Task 8: Sysbench 스파이크 러너 스크립트 (bash) [unspecified-high]
├── Task 9: HammerDB TPC-C 자동화 스크립트 (Tcl + bash) [unspecified-high]
├── Task 10: MySQL 모니터링 수집 스크립트 (Python) [unspecified-high]
└── Task 11: 결과 시각화 스크립트 (Python matplotlib) [unspecified-high]

Wave 3 (Integration + Orchestration — after Wave 2):
├── Task 12: 벤치마크 오케스트레이션 러너 (master script) [unspecified-high]
├── Task 13: OS 튜닝 스크립트 (클라이언트 VM용) [quick]
└── Task 14: README + 실행 가이드 [writing]

Wave 4 (Infra Provisioning + Benchmark Execution — after Wave 3, 유저 인증정보 수령 후):
├── Task 15: Terraform apply (AWS + OCI) + 연결 검증 [deep]
├── Task 16: SSH 접속 → 벤치마크 도구 설치 + OS 튜닝 (양쪽 VM) [deep]
├── Task 17: Sysbench 데이터 준비 + 스파이크 벤치마크 실행 (Aurora) [deep]
├── Task 18: Sysbench 데이터 준비 + 스파이크 벤치마크 실행 (OCI MDS) [deep]
├── Task 19: HammerDB TPC-C 실행 (Aurora + OCI) [deep]
└── Task 20: 결과 수집 + 시각화 + 보고서 생성 [unspecified-high]

Wave FINAL (After ALL tasks — 4 parallel reviews, then user okay):
├── Task F1: Plan compliance audit (oracle)
├── Task F2: Code quality review (unspecified-high)
├── Task F3: Real manual QA (unspecified-high)
└── Task F4: Scope fidelity check (deep)
-> Present results -> Get explicit user okay
```

### Dependency Matrix

| Task | Depends On | Blocks | Wave |
|------|-----------|--------|------|
| T1 | - | T4, T6 | 1 |
| T2 | - | T5, T7 | 1 |
| T3 | - | T8 | 1 |
| T4 | T1 | T15 | 2 |
| T5 | T2 | T15 | 2 |
| T6 | T1 | T15 | 2 |
| T7 | T2 | T15 | 2 |
| T8 | T3 | T12 | 2 |
| T9 | - | T12 | 2 |
| T10 | - | T12 | 2 |
| T11 | - | T20 | 2 |
| T12 | T8, T9, T10 | T17, T18, T19 | 3 |
| T13 | - | T16 | 3 |
| T14 | T1-T13 | - | 3 |
| T15 | T4, T5, T6, T7 | T16 | 4 |
| T16 | T13, T15 | T17, T18, T19 | 4 |
| T17 | T12, T16 | T20 | 4 |
| T18 | T12, T16 | T20 | 4 |
| T19 | T12, T16 | T20 | 4 |
| T20 | T11, T17, T18, T19 | F1-F4 | 4 |

### Agent Dispatch Summary

- **Wave 1**: 3 tasks — T1→`quick`, T2→`quick`, T3→`deep`
- **Wave 2**: 8 tasks — T4-T7→`quick`, T8-T11→`unspecified-high`
- **Wave 3**: 3 tasks — T12→`unspecified-high`, T13→`quick`, T14→`writing`
- **Wave 4**: 6 tasks — T15-T16→`deep`, T17-T19→`deep`, T20→`unspecified-high`
- **FINAL**: 4 tasks — F1→`oracle`, F2→`unspecified-high`, F3→`unspecified-high`, F4→`deep`

---

## TODOs

- [ ] 1. AWS Terraform — Providers, Variables, VPC/Subnets/Security Groups

  **What to do**:
  - `terraform/aws/` 디렉토리 생성
  - `providers.tf`: AWS provider 설정 (region variable, required_providers with version constraint)
  - `variables.tf`: region, vpc_cidr, db_password(sensitive), db_username, key_pair_name 등 변수 정의. `terraform.tfvars.example` 포함
  - `vpc.tf`: VPC (10.0.0.0/16), private subnet 2개 (DB용, 서로 다른 AZ), public subnet 1개 (벤치마크 클라이언트용)
  - `security_groups.tf`: Aurora SG (3306 inbound from client SG only), Client SG (22 inbound from 특정 IP, outbound all)
  - `outputs.tf`: vpc_id, subnet_ids, security_group_ids 출력
  - Internet Gateway + NAT Gateway (클라이언트 VM에서 패키지 설치용)
  - DB subnet group 리소스

  **Must NOT do**:
  - 크레덴셜 하드코딩
  - Aurora 리소스 포함 (Task 4에서 처리)
  - EC2 인스턴스 포함 (Task 6에서 처리)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 표준 Terraform VPC 패턴, 단일 모듈 작업
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `playwright`: 브라우저 작업 없음

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 2, 3)
  - **Blocks**: Tasks 4, 6
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - Terraform AWS VPC module 패턴: `aws_vpc` + `aws_subnet` + `aws_internet_gateway` + `aws_nat_gateway` + `aws_route_table`
  - Aurora는 최소 2개 AZ의 subnet 필요 → DB subnet group에 2개 private subnet

  **External References**:
  - AWS Provider docs: https://registry.terraform.io/providers/hashicorp/aws/latest/docs
  - VPC resource: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc

  **WHY Each Reference Matters**:
  - Aurora cluster는 DB subnet group 필수 → 2개 AZ private subnet 미 생성해야 Task 4에서 참조 가능
  - Security group은 Aurora SG ↔ Client SG 상호 참조 → 같은 모듈에서 정의

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Terraform validate 성공
    Tool: Bash
    Preconditions: terraform/aws/ 디렉토리에 .tf 파일 존재
    Steps:
      1. cd terraform/aws && terraform init -backend=false
      2. terraform validate
    Expected Result: "Success! The configuration is valid." 출력, exit code 0
    Failure Indicators: "Error:" 포함 메시지, exit code != 0
    Evidence: .sisyphus/evidence/task-1-terraform-validate.txt

  Scenario: 크레덴셜 하드코딩 없음
    Tool: Bash (grep)
    Preconditions: terraform/aws/ 디렉토리 존재
    Steps:
      1. grep -rn "AKIA\|aws_access_key\|aws_secret_key\|password\s*=" terraform/aws/*.tf
    Expected Result: password 관련 매치는 variable 선언부(sensitive=true)만 존재
    Failure Indicators: 실제 키 값이나 평문 패스워드 발견
    Evidence: .sisyphus/evidence/task-1-no-credentials.txt

  Scenario: terraform.tfvars.example 존재 확인
    Tool: Bash
    Preconditions: terraform/aws/ 디렉토리 존재
    Steps:
      1. test -f terraform/aws/terraform.tfvars.example && echo "EXISTS"
    Expected Result: "EXISTS" 출력
    Failure Indicators: 파일 미존재
    Evidence: .sisyphus/evidence/task-1-tfvars-example.txt
  ```

  **Commit**: YES (group with T4, T6)
  - Message: `feat(aws): add VPC, Aurora MySQL, EC2 client Terraform module`
  - Files: `terraform/aws/*`
  - Pre-commit: `cd terraform/aws && terraform validate`

- [ ] 2. OCI Terraform — Providers, Variables, VCN/Subnets/NSG

  **What to do**:
  - `terraform/oci/` 디렉토리 생성
  - `providers.tf`: OCI provider 설정 (tenancy_ocid, user_ocid, fingerprint, private_key_path, region — 모두 variable)
  - `variables.tf`: compartment_id, region, vcn_cidr, db_admin_password(sensitive), ssh_public_key 등. `terraform.tfvars.example` 포함
  - `vcn.tf`: VCN (10.1.0.0/16), private subnet (MySQL MDS용), public subnet (벤치마크 클라이언트용)
  - `nsg.tf`: MySQL NSG (3306 inbound from client subnet CIDR only), Client NSG (22 inbound from 특정 IP)
  - `outputs.tf`: vcn_id, subnet_ids, nsg_ids 출력
  - Internet Gateway + Service Gateway (OCI 서비스 접근용)
  - Route tables + DHCP options

  **Must NOT do**:
  - 크레덴셜 하드코딩
  - MySQL MDS 리소스 포함 (Task 5에서 처리)
  - Compute 인스턴스 포함 (Task 7에서 처리)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 표준 Terraform OCI VCN 패턴, 단일 모듈 작업
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Tasks 5, 7
  - **Blocked By**: None

  **References**:

  **Pattern References**:
  - OCI VCN 패턴: `oci_core_vcn` + `oci_core_subnet` + `oci_core_internet_gateway` + `oci_core_service_gateway`
  - MySQL MDS는 private subnet 필수

  **External References**:
  - OCI Provider docs: https://registry.terraform.io/providers/oracle/oci/latest/docs
  - OCI MySQL MDS docs: https://docs.oracle.com/en-us/iaas/mysql-database/

  **WHY Each Reference Matters**:
  - OCI provider는 인증 방식이 AWS와 다름 (API key 기반) → provider 설정 정확히 해야 함
  - MySQL MDS는 private subnet + NSG 조합 필수 → 네트워크 먼저 구성

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Terraform validate 성공
    Tool: Bash
    Preconditions: terraform/oci/ 디렉토리에 .tf 파일 존재
    Steps:
      1. cd terraform/oci && terraform init -backend=false
      2. terraform validate
    Expected Result: "Success! The configuration is valid." 출력, exit code 0
    Failure Indicators: "Error:" 포함 메시지
    Evidence: .sisyphus/evidence/task-2-terraform-validate.txt

  Scenario: 크레덴셜 하드코딩 없음
    Tool: Bash (grep)
    Preconditions: terraform/oci/ 디렉토리 존재
    Steps:
      1. grep -rn "ocid1\.\|BEGIN RSA\|private_key\s*=" terraform/oci/*.tf | grep -v "variable\|description"
    Expected Result: 매치 없음 (exit code 1)
    Failure Indicators: 실제 OCID나 키 값 발견
    Evidence: .sisyphus/evidence/task-2-no-credentials.txt
  ```

  **Commit**: YES (group with T5, T7)
  - Message: `feat(oci): add VCN, MySQL MDS with thread pool, Compute client Terraform module`
  - Files: `terraform/oci/*`
  - Pre-commit: `cd terraform/oci && terraform validate`

- [ ] 3. Sysbench 커스텀 Lua 티켓팅 워크로드 스크립트

  **What to do**:
  - `scripts/sysbench/ticketing_workload.lua` 작성
  - 스키마: `tickets` 테이블 (ticket_id PK, event_id, status ENUM('available','reserved','sold'), reserved_at, version) + `orders` 테이블 (order_id AUTO_INCREMENT PK, ticket_id FK, user_id, created_at)
  - `prepare()`: 테이블 생성 + 10,000 tickets 삽입 (100개 이벤트에 분산)
  - `event()`: Pareto 분포로 hot row 선택 (상위 5% row에 80% 트래픽) → `BEGIN` → `SELECT ticket_id, status FROM tickets WHERE ticket_id = ? FOR UPDATE` → status='available'이면 `UPDATE tickets SET status='reserved'` → `INSERT INTO orders` → `COMMIT`
  - `cleanup()`: 테이블 DROP
  - CLI 옵션: `--num-tickets`, `--hot-rows` (hot row 비율), `--mysql-host`, `--mysql-user`, `--mysql-password`, `--mysql-db`
  - Pareto 분포 구현: `math.random(1,100) <= 80` → hot range, else cold range

  **Must NOT do**:
  - sysbench 내장 테이블(sbtest) 사용 — 커스텀 스키마만
  - 외부 라이브러리 의존

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Sysbench Lua API 이해 + Pareto 분포 + 트랜잭션 패턴 정확성 필요
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 2)
  - **Blocks**: Task 8
  - **Blocked By**: None

  **References**:

  **External References**:
  - Percona custom sysbench scripts: https://www.percona.com/blog/creating-custom-sysbench-scripts/
  - Sysbench Lua API: `sysbench.cmdline.options`, `sysbench.sql.driver()`, `drv:connect()`, `con:query()`, `con:prepare()`, `stmt:bind_param()`
  - Ronald Bradford sysbench example: https://gist.github.com/ronaldbradford/93a810971d62c8b1a4c92e1874000811

  **WHY Each Reference Matters**:
  - Percona 블로그: sysbench Lua API의 `prepare/run/cleanup` 라이프사이클과 `sysbench.cmdline.options` 패턴 참조
  - Ronald Bradford gist: standalone Lua 스크립트의 `thread_init/thread_done/event` 구조 참조

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Lua 문법 검증
    Tool: Bash
    Preconditions: scripts/sysbench/ticketing_workload.lua 존재
    Steps:
      1. luac -p scripts/sysbench/ticketing_workload.lua 2>&1 || lua -e "loadfile('scripts/sysbench/ticketing_workload.lua')" 2>&1
    Expected Result: exit code 0 (문법 에러 없음)
    Failure Indicators: "syntax error" 또는 "unexpected symbol"
    Evidence: .sisyphus/evidence/task-3-lua-syntax.txt

  Scenario: 필수 함수 존재 확인
    Tool: Bash (grep)
    Preconditions: Lua 파일 존재
    Steps:
      1. grep -c "function prepare\|function event\|function cleanup\|function thread_init\|function thread_done" scripts/sysbench/ticketing_workload.lua
    Expected Result: 5 (모든 필수 함수 존재)
    Failure Indicators: 5 미만
    Evidence: .sisyphus/evidence/task-3-functions.txt

  Scenario: 트랜잭션 패턴 확인
    Tool: Bash (grep)
    Preconditions: Lua 파일 존재
    Steps:
      1. grep -c "FOR UPDATE\|BEGIN\|COMMIT\|INSERT INTO.*orders" scripts/sysbench/ticketing_workload.lua
    Expected Result: 4 이상 (SELECT FOR UPDATE, BEGIN, COMMIT, INSERT 모두 존재)
    Failure Indicators: 4 미만
    Evidence: .sisyphus/evidence/task-3-transaction-pattern.txt
  ```

  **Commit**: YES (group with T8)
  - Message: `feat(scripts): add sysbench benchmark scripts (oltp spike + ticketing Lua)`
  - Files: `scripts/sysbench/*`

- [ ] 4. AWS Terraform — Aurora MySQL Cluster + Parameter Groups

  **What to do**:
  - `terraform/aws/aurora.tf`: `aws_rds_cluster` (engine=aurora-mysql, engine_version=8.0.mysql_aurora.3.04.0, single writer, skip_final_snapshot=true for benchmark)
  - `terraform/aws/aurora.tf`: `aws_rds_cluster_instance` count=1 (single writer only), instance_class=db.r6g.4xlarge
  - `terraform/aws/parameter_groups.tf`: `aws_rds_cluster_parameter_group` (family=aurora-mysql8.0, binlog_format=ROW)
  - `terraform/aws/parameter_groups.tf`: `aws_db_parameter_group` (family=aurora-mysql8.0):
    - `max_connections = 5000`
    - `innodb_buffer_pool_size = {DBInstanceClassMemory*3/4}` (~96GB)
    - `innodb_flush_log_at_trx_commit = 2`
    - `innodb_lock_wait_timeout = 50`
    - `innodb_thread_concurrency = 0`
    - `innodb_concurrency_tickets = 5000`
    - `long_query_time = 2`, `slow_query_log = 1`
  - Performance Insights 활성화, Enhanced Monitoring 60초 간격
  - CloudWatch logs export: error, slowquery
  - outputs.tf에 cluster_endpoint, reader_endpoint, port 추가

  **Must NOT do**:
  - Aurora Serverless v2 사용
  - Multi-AZ / reader replica (count=1 writer만)
  - 크레덴셜 하드코딩

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 표준 Aurora Terraform 패턴, 파라미터 값은 이미 확정
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 5, 6, 7, 8, 9, 10, 11)
  - **Blocks**: Task 15
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - terraform-aws-modules/terraform-aws-rds-aurora: `aws_rds_cluster` + `aws_rds_cluster_instance` 패턴
  - Aurora MySQL 3.x parameter group family: `aurora-mysql8.0`

  **External References**:
  - Aurora MySQL parameter reference: https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Reference.ParameterGroups.html
  - `{DBInstanceClassMemory*3/4}` 동적 버퍼풀 공식: Aurora 전용 표현식

  **WHY Each Reference Matters**:
  - parameter group family가 `aurora-mysql8.0`이어야 함 (`mysql8.0` 아님) — 잘못 쓰면 apply 실패
  - `innodb_buffer_pool_size`는 Aurora 동적 표현식 사용 — 하드코딩하면 인스턴스 변경 시 깨짐

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Terraform validate 성공 (Aurora 포함)
    Tool: Bash
    Preconditions: Task 1 완료, terraform/aws/ 에 vpc.tf + aurora.tf + parameter_groups.tf 존재
    Steps:
      1. cd terraform/aws && terraform init -backend=false
      2. terraform validate
    Expected Result: exit code 0
    Failure Indicators: "Error:" 메시지
    Evidence: .sisyphus/evidence/task-4-terraform-validate.txt

  Scenario: Aurora 파라미터 그룹에 필수 값 설정 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "max_connections\|innodb_buffer_pool_size\|innodb_flush_log_at_trx_commit\|innodb_lock_wait_timeout" terraform/aws/parameter_groups.tf
    Expected Result: 4 이상
    Evidence: .sisyphus/evidence/task-4-params.txt

  Scenario: Single writer 확인 (count=1)
    Tool: Bash (grep)
    Steps:
      1. grep "count" terraform/aws/aurora.tf | head -5
    Expected Result: count = 1 (또는 count 없이 단일 리소스)
    Failure Indicators: count > 1
    Evidence: .sisyphus/evidence/task-4-single-writer.txt
  ```

  **Commit**: YES (group with T1, T6)
  - Message: `feat(aws): add VPC, Aurora MySQL, EC2 client Terraform module`
  - Files: `terraform/aws/*`
  - Pre-commit: `cd terraform/aws && terraform validate`

- [ ] 5. OCI Terraform — MySQL MDS + Thread Pool Configuration

  **What to do**:
  - `terraform/oci/mysql_config.tf`: `oci_mysql_mysql_configuration` (별도 리소스, immutable이므로 생성 시 확정):
    - `thread_pool_size = 16` (OCPU 수)
    - `thread_pool_max_transactions_limit = 512` (16 × 32)
    - `thread_pool_algorithm = 1` (High Concurrency)
    - `thread_pool_query_threads_per_group = 2`
    - `thread_pool_stall_limit = 10` (100ms)
    - `max_connections = 5000` (Aurora와 동일)
    - `innodb_buffer_pool_size = 103079215104` (96GB in bytes)
    - `innodb_flush_log_at_trx_commit = 2`
    - `innodb_lock_wait_timeout = 50`
    - `long_query_time = 2`, `slow_query_log = ON`
  - `terraform/oci/mysql.tf`: `oci_mysql_mysql_db_system`:
    - shape_name = OCI shape with 8 OCPU (16 vCPU), 128GB — 정확한 shape name은 `oci mysql shape list` 로 확인 필요, 변수화
    - configuration_id = 위 config 리소스 참조
    - data_storage_size_in_gb = 100
    - is_highly_available = false (벤치마크용 단일 인스턴스)
    - admin_username, admin_password (variable)
    - crash_recovery = ENABLED
  - outputs.tf에 db_system_id, endpoint hostname/ip, port 추가

  **Must NOT do**:
  - is_highly_available = true (HA 비활성화 — Aurora도 single writer)
  - thread pool 값 하드코딩 대신 variable로 오버라이드 가능하게 (기본값은 위 값)
  - 크레덴셜 하드코딩

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: OCI Terraform 리소스 2개, 파라미터 값 확정됨
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 6, 7, 8, 9, 10, 11)
  - **Blocks**: Task 15
  - **Blocked By**: Task 2

  **References**:

  **External References**:
  - OCI MySQL Configuration: https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/mysql_mysql_configuration.html
  - OCI MySQL DB System: https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/mysql_mysql_db_system.html
  - Thread pool variables: https://docs.oracle.com/cd/E17952_01/mysql-8.0-en/thread-pool-tuning.html

  **WHY Each Reference Matters**:
  - `oci_mysql_mysql_configuration`은 **immutable** — 생성 후 변경 불가, destroy/recreate 필요. 값을 정확히 설정해야 함
  - shape_name은 리전마다 다를 수 있음 → variable로 처리하고 tfvars.example에 예시 제공

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Terraform validate 성공 (MySQL MDS 포함)
    Tool: Bash
    Preconditions: Task 2 완료, terraform/oci/ 에 vcn.tf + mysql.tf + mysql_config.tf 존재
    Steps:
      1. cd terraform/oci && terraform init -backend=false
      2. terraform validate
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-5-terraform-validate.txt

  Scenario: Thread pool 설정 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "thread_pool_size\|thread_pool_max_transactions_limit\|thread_pool_algorithm\|thread_pool_stall_limit" terraform/oci/mysql_config.tf
    Expected Result: 4 이상
    Evidence: .sisyphus/evidence/task-5-thread-pool.txt

  Scenario: max_connections 양쪽 동일 확인
    Tool: Bash (grep)
    Steps:
      1. grep "max_connections" terraform/oci/mysql_config.tf
    Expected Result: 5000 포함
    Failure Indicators: 5000이 아닌 값
    Evidence: .sisyphus/evidence/task-5-max-connections.txt
  ```

  **Commit**: YES (group with T2, T7)
  - Message: `feat(oci): add VCN, MySQL MDS with thread pool, Compute client Terraform module`
  - Files: `terraform/oci/*`
  - Pre-commit: `cd terraform/oci && terraform validate`

- [ ] 6. AWS Terraform — EC2 벤치마크 클라이언트 + Outputs

  **What to do**:
  - `terraform/aws/ec2_client.tf`: `aws_instance`:
    - AMI: Ubuntu 22.04 LTS (data source `aws_ami` 사용)
    - instance_type = c6i.4xlarge (16 vCPU, 32GB — 충분한 로드 생성 능력)
    - subnet_id = public subnet (Aurora와 같은 AZ)
    - vpc_security_group_ids = client SG
    - key_name = variable
    - root_block_device: gp3, 100GB
    - associate_public_ip_address = true (SSH 접속용)
  - `terraform/aws/data.tf`: `data "aws_ami"` Ubuntu 22.04 최신 AMI 조회
  - outputs.tf에 client_public_ip, client_instance_id 추가

  **Must NOT do**:
  - user_data로 벤치마크 도구 설치 (SSH로 직접 수행)
  - Spot 인스턴스 사용 (벤치마크 중 회수되면 안 됨)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 단일 EC2 인스턴스 + AMI data source
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 5, 7, 8, 9, 10, 11)
  - **Blocks**: Task 15
  - **Blocked By**: Task 1

  **References**:

  **External References**:
  - AWS EC2 instance: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance
  - c6i.4xlarge specs: 16 vCPU, 32GB RAM, up to 12.5 Gbps network

  **WHY Each Reference Matters**:
  - 벤치마크 클라이언트는 Aurora와 같은 AZ에 배치해야 네트워크 레이턴시 변수 제거
  - c6i.4xlarge는 4096 threads 생성에 충분한 CPU (16 vCPU)

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: EC2 리소스 정의 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "aws_instance\|aws_ami" terraform/aws/ec2_client.tf terraform/aws/data.tf
    Expected Result: 2 이상 (instance + ami data source)
    Evidence: .sisyphus/evidence/task-6-ec2.txt

  Scenario: 인스턴스 타입 확인
    Tool: Bash (grep)
    Steps:
      1. grep "instance_type" terraform/aws/ec2_client.tf
    Expected Result: "c6i.4xlarge" 포함
    Evidence: .sisyphus/evidence/task-6-instance-type.txt
  ```

  **Commit**: YES (group with T1, T4)
  - Message: `feat(aws): add VPC, Aurora MySQL, EC2 client Terraform module`
  - Files: `terraform/aws/*`

- [ ] 7. OCI Terraform — Compute 벤치마크 클라이언트 + Outputs

  **What to do**:
  - `terraform/oci/compute_client.tf`: `oci_core_instance`:
    - shape = VM.Standard.E4.Flex (shape_config: ocpus=16, memory_in_gbs=32)
    - availability_domain = MySQL MDS와 동일 AD
    - subnet_id = public subnet
    - source_details: Oracle Linux 8 또는 Ubuntu 22.04 이미지 (data source)
    - metadata: ssh_authorized_keys = variable
    - create_vnic_details: assign_public_ip = true, nsg_ids = client NSG
  - `terraform/oci/data.tf`: `data "oci_core_images"` 이미지 조회 + `data "oci_identity_availability_domains"` AD 조회
  - outputs.tf에 client_public_ip, client_instance_id 추가

  **Must NOT do**:
  - cloud-init으로 벤치마크 도구 설치
  - Preemptible 인스턴스 사용

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 단일 Compute 인스턴스 + data sources
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 5, 6, 8, 9, 10, 11)
  - **Blocks**: Task 15
  - **Blocked By**: Task 2

  **References**:

  **External References**:
  - OCI Compute instance: https://docs.oracle.com/en-us/iaas/tools/terraform-provider-oci/latest/docs/r/core_instance.html
  - VM.Standard.E4.Flex: AMD EPYC, flexible OCPU/memory

  **WHY Each Reference Matters**:
  - Flex shape은 ocpus + memory_in_gbs를 shape_config 블록에서 지정 — 빠뜨리면 최소 사양으로 생성됨
  - MySQL MDS와 같은 AD에 배치 필수

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Compute 리소스 정의 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "oci_core_instance\|oci_core_images\|oci_identity_availability_domains" terraform/oci/compute_client.tf terraform/oci/data.tf
    Expected Result: 3 이상
    Evidence: .sisyphus/evidence/task-7-compute.txt

  Scenario: Flex shape 설정 확인
    Tool: Bash (grep)
    Steps:
      1. grep -A2 "shape_config" terraform/oci/compute_client.tf
    Expected Result: ocpus = 16, memory_in_gbs = 32 포함
    Evidence: .sisyphus/evidence/task-7-flex-shape.txt
  ```

  **Commit**: YES (group with T2, T5)
  - Message: `feat(oci): add VCN, MySQL MDS with thread pool, Compute client Terraform module`
  - Files: `terraform/oci/*`

- [ ] 8. Sysbench 스파이크 러너 스크립트 (Bash)

  **What to do**:
  - `scripts/sysbench/run_spike_benchmark.sh` 작성
  - CLI 인자: `--host`, `--port`, `--user`, `--password`, `--db`, `--threads-list` (기본값 "32,64,128,256,512,1024,2048,4096"), `--duration` (기본 60), `--report-interval` (기본 5), `--runs` (반복 횟수, 기본 3), `--warmup` (워밍업 초, 기본 60), `--output-dir`
  - Phase 1: `sysbench oltp_read_write prepare` (tables=10, table-size=10000000)
  - Phase 2: 각 thread 수에 대해 `--runs`회 반복:
    - 워밍업 실행 (결과 버림)
    - 본 측정 실행 (`--report-interval` 단위 출력 → `{output-dir}/{host}_{threads}t_run{N}.log`)
    - 서버 안정화 대기 30초
  - Phase 3: Pareto 분포 테스트 (별도 함수):
    - `sysbench oltp_read_write --rand-type=pareto --rand-pareto-h=0.1 --threads=4096 --time=120`
  - Phase 4: 커스텀 Lua 티켓팅 테스트 (Task 3의 스크립트 호출):
    - `sysbench ticketing_workload.lua` 동일 thread 단계별 실행
  - Phase 5: `sysbench oltp_read_write cleanup`
  - 모든 출력에 타임스탬프 prefix
  - `set -euo pipefail` + 에러 핸들링

  **Must NOT do**:
  - 인터랙티브 입력 요구 (모든 파라미터 CLI 또는 env)
  - sysbench 설치 (이미 설치된 것으로 가정)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 복잡한 bash 스크립트, 다단계 로직, 에러 핸들링
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4-7, 9, 10, 11)
  - **Blocks**: Task 12
  - **Blocked By**: Task 3

  **References**:

  **External References**:
  - Sysbench CLI: `sysbench [options] [testname] [command]`
  - `--report-interval=N`: N초마다 중간 통계 출력 (tps, qps, lat 95%)
  - `--rand-type=pareto --rand-pareto-h=0.1`: Pareto 분포 (상위 20%에 80% 접근)
  - Oracle 공식 벤치마크 방법론: 단계별 thread 증가 + Pareto access pattern

  **WHY Each Reference Matters**:
  - `--report-interval` 출력 형식이 시각화 스크립트(Task 11)의 파싱 대상 → 형식 일관성 필수
  - Pareto h=0.1은 Oracle 공식 벤치마크와 동일 파라미터 → 결과 비교 가능

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: shellcheck 통과
    Tool: Bash
    Steps:
      1. shellcheck scripts/sysbench/run_spike_benchmark.sh
    Expected Result: exit code 0 (경고/에러 없음)
    Evidence: .sisyphus/evidence/task-8-shellcheck.txt

  Scenario: CLI 인자 파싱 확인
    Tool: Bash
    Steps:
      1. bash scripts/sysbench/run_spike_benchmark.sh --help 2>&1
    Expected Result: --host, --threads-list, --duration, --runs, --output-dir 옵션 설명 출력
    Failure Indicators: "unrecognized option" 또는 usage 미출력
    Evidence: .sisyphus/evidence/task-8-help.txt

  Scenario: set -euo pipefail 확인
    Tool: Bash (grep)
    Steps:
      1. head -5 scripts/sysbench/run_spike_benchmark.sh | grep "set -euo pipefail"
    Expected Result: 매치 1건
    Evidence: .sisyphus/evidence/task-8-strict-mode.txt
  ```

  **Commit**: YES (group with T3)
  - Message: `feat(scripts): add sysbench benchmark scripts (oltp spike + ticketing Lua)`
  - Files: `scripts/sysbench/*`

- [ ] 9. HammerDB TPC-C 자동화 스크립트 (Tcl + Bash)

  **What to do**:
  - `scripts/hammerdb/tpcc_build.tcl`: 스키마 빌드 스크립트
    - `dbset db mysql`, connection 설정 (host/port/user/password 환경변수에서 읽기)
    - `diset tpcc mysql_count_ware 100` (약 10GB 데이터)
    - `buildschema` + `waittocomplete`
  - `scripts/hammerdb/tpcc_run.tcl`: 벤치마크 실행 스크립트
    - Virtual users 수를 환경변수에서 읽기
    - `diset tpcc mysql_rampup 2` (2분 워밍업)
    - `diset tpcc mysql_duration 10` (10분 측정)
    - `vuset vu $VU_COUNT` → `vucreate` → `vurun` → `waittocomplete`
    - NOPM (New Orders Per Minute) 결과 캡처
  - `scripts/hammerdb/run_hammerdb.sh`: Bash wrapper
    - CLI 인자: `--host`, `--port`, `--user`, `--password`, `--vu-list` (기본 "8,16,32,64,128,256,512"), `--output-dir`
    - 각 VU 수에 대해 tpcc_run.tcl 호출, 결과를 `{output-dir}/{host}_{vu}vu.log`에 저장
    - `set -euo pipefail`

  **Must NOT do**:
  - HammerDB 설치 (SSH로 직접 수행)
  - GUI 모드 사용 (CLI only: `hammerdbcli`)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Tcl 스크립팅 + HammerDB API 이해 필요
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4-8, 10, 11)
  - **Blocks**: Task 12
  - **Blocked By**: None

  **References**:

  **External References**:
  - HammerDB CLI automation: https://www.hammerdb.com/blog/uncategorized/driving-hammerdbcli-from-a-bash-script/
  - HammerDB MySQL TPC-C: `dbset db mysql` + `diset tpcc` 패턴
  - `waittocomplete` / `vucomplete` 폴링 패턴

  **WHY Each Reference Matters**:
  - HammerDB CLI는 Tcl 인터프리터 기반 → heredoc 또는 .tcl 파일로 스크립트 전달
  - `waittocomplete`는 blocking 호출 → 스크립트 종료 시점 제어에 필수

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Bash wrapper shellcheck 통과
    Tool: Bash
    Steps:
      1. shellcheck scripts/hammerdb/run_hammerdb.sh
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-9-shellcheck.txt

  Scenario: Tcl 문법 검증
    Tool: Bash
    Steps:
      1. tclsh scripts/hammerdb/tpcc_build.tcl 2>&1 | head -1 || echo "Tcl syntax check requires hammerdbcli"
    Expected Result: 문법 에러 없음 (또는 hammerdbcli 미설치 안내)
    Evidence: .sisyphus/evidence/task-9-tcl-syntax.txt

  Scenario: 환경변수 기반 설정 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "DB_HOST\|DB_PORT\|DB_USER\|DB_PASSWORD\|VU_COUNT" scripts/hammerdb/tpcc_run.tcl scripts/hammerdb/tpcc_build.tcl
    Expected Result: 4 이상 (주요 환경변수 참조)
    Evidence: .sisyphus/evidence/task-9-env-vars.txt
  ```

  **Commit**: YES
  - Message: `feat(scripts): add HammerDB TPC-C automation`
  - Files: `scripts/hammerdb/*`

- [ ] 10. MySQL 모니터링 수집 스크립트 (Python)

  **What to do**:
  - `scripts/monitoring/monitor.py` 작성
  - CLI 인자 (argparse): `--host`, `--port`, `--user`, `--password`, `--interval` (기본 1초), `--duration` (기본 600초), `--output` (CSV 파일 경로)
  - 수집 메트릭 (SHOW GLOBAL STATUS):
    - `Threads_running`, `Threads_connected`
    - `Questions`, `Queries`, `Com_select`, `Com_insert`, `Com_update`, `Com_commit`, `Com_rollback`
    - `Innodb_row_lock_waits`, `Innodb_row_lock_time`, `Innodb_row_lock_current_waits`
    - `Innodb_buffer_pool_reads`, `Innodb_buffer_pool_read_requests`
    - `Slow_queries`, `Aborted_connects`, `Aborted_clients`
  - OCI Thread Pool 메트릭 (선택적, `--thread-pool` 플래그):
    - `SELECT * FROM performance_schema.tp_thread_group_stats` (가능한 경우)
    - 또는 `SHOW GLOBAL STATUS LIKE 'Threadpool%'`
  - CSV 출력 형식: `timestamp,threads_running,threads_connected,com_select,com_update,com_insert,innodb_row_lock_waits,innodb_row_lock_time,...`
  - 백그라운드 실행 지원: `--daemon` 플래그로 백그라운드 모드
  - 의존성: `mysql-connector-python` 만 (표준 라이브러리 + 1개)
  - `requirements.txt` 포함

  **Must NOT do**:
  - Grafana/Prometheus 연동
  - 복잡한 ORM 사용
  - 모니터링 자체가 DB에 부하를 주는 무거운 쿼리

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: MySQL 프로토콜 이해 + 시계열 수집 로직 + CSV 출력
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4-9, 11)
  - **Blocks**: Task 12
  - **Blocked By**: None

  **References**:

  **External References**:
  - MySQL SHOW GLOBAL STATUS: https://dev.mysql.com/doc/refman/8.0/en/show-status.html
  - MySQL Enterprise Thread Pool monitoring: `performance_schema.tp_thread_group_stats`
  - mysql-connector-python: https://dev.mysql.com/doc/connector-python/en/

  **WHY Each Reference Matters**:
  - SHOW GLOBAL STATUS는 누적 카운터 → 델타 계산 필요 (현재값 - 이전값 = 초당 변화량)
  - Thread pool 메트릭은 OCI에서만 사용 가능 → `--thread-pool` 플래그로 분기

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Python 문법 검증
    Tool: Bash
    Steps:
      1. python3 -m py_compile scripts/monitoring/monitor.py
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-10-py-compile.txt

  Scenario: CLI help 출력 확인
    Tool: Bash
    Steps:
      1. python3 scripts/monitoring/monitor.py --help 2>&1
    Expected Result: --host, --port, --interval, --duration, --output, --thread-pool 옵션 표시
    Evidence: .sisyphus/evidence/task-10-help.txt

  Scenario: requirements.txt 존재
    Tool: Bash
    Steps:
      1. test -f scripts/monitoring/requirements.txt && cat scripts/monitoring/requirements.txt
    Expected Result: mysql-connector-python 포함
    Evidence: .sisyphus/evidence/task-10-requirements.txt
  ```

  **Commit**: YES (group with T11)
  - Message: `feat(scripts): add MySQL monitoring + visualization scripts`
  - Files: `scripts/monitoring/*`

- [ ] 11. 결과 시각화 스크립트 (Python matplotlib)

  **What to do**:
  - `scripts/visualization/visualize.py` 작성
  - CLI 인자 (argparse): `--aurora-dir` (Aurora 결과 디렉토리), `--oci-dir` (OCI 결과 디렉토리), `--output-dir` (차트 출력 디렉토리)
  - 차트 1: **TPS vs Thread Count** — X축: thread 수 (32~4096 log scale), Y축: TPS. Aurora(빨강) vs OCI(파랑) 라인. 3회 반복의 중앙값 + 에러바(min/max)
  - 차트 2: **Latency Percentiles vs Thread Count** — p50, p95, p99 각각 subplot. Aurora vs OCI
  - 차트 3: **TPS Time Series (스파이크 구간)** — `--report-interval` 출력 파싱. 4096 threads 구간의 시계열 TPS
  - 차트 4: **Error Rate vs Thread Count** — 에러 수/에러율 비교
  - 차트 5: **Monitoring Overlay** — monitor.py CSV 읽어서 Threads_running + Innodb_row_lock_waits 시계열
  - Sysbench 로그 파싱: `[ Ns ] thds: N tps: N.NN qps: N.NN lat (ms,95%): N.NN err/s: N.NN` 정규식
  - Sysbench 최종 요약 파싱: `transactions:`, `queries:`, `95th percentile:`, `99th percentile:`
  - 모든 차트 PNG 300dpi 저장
  - `requirements.txt`: matplotlib, numpy
  - 한글 폰트 설정 불필요 (영문 레이블 사용)

  **Must NOT do**:
  - 인터랙티브 차트 (Jupyter/Plotly)
  - 웹 대시보드

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 정규식 파싱 + matplotlib 다중 차트 + 통계 처리
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4-10)
  - **Blocks**: Task 20
  - **Blocked By**: None

  **References**:

  **External References**:
  - Sysbench `--report-interval` 출력 형식: `[ 10s ] thds: 64 tps: 1234.56 qps: 12345.67 (r/w/o: 8641.97/2469.13/1234.56) lat (ms,95%): 45.23 err/s: 0.00 reconn/s: 0.00`
  - Sysbench 최종 요약 형식: `SQL statistics:` 블록 내 `transactions:`, `queries:`, `Latency (ms):` 하위 `avg:`, `95th percentile:`, `99th percentile:`
  - matplotlib savefig: `plt.savefig(path, dpi=300, bbox_inches='tight')`

  **WHY Each Reference Matters**:
  - Sysbench 출력 형식이 버전마다 미세하게 다를 수 있음 → 정규식을 유연하게 작성
  - TPS cliff 시각화가 벤치마크의 핵심 메시지 → 차트 1이 가장 중요

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Python 문법 검증
    Tool: Bash
    Steps:
      1. python3 -m py_compile scripts/visualization/visualize.py
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-11-py-compile.txt

  Scenario: CLI help 출력 확인
    Tool: Bash
    Steps:
      1. python3 scripts/visualization/visualize.py --help 2>&1
    Expected Result: --aurora-dir, --oci-dir, --output-dir 옵션 표시
    Evidence: .sisyphus/evidence/task-11-help.txt

  Scenario: requirements.txt 존재
    Tool: Bash
    Steps:
      1. test -f scripts/visualization/requirements.txt && cat scripts/visualization/requirements.txt
    Expected Result: matplotlib, numpy 포함
    Evidence: .sisyphus/evidence/task-11-requirements.txt
  ```

  **Commit**: YES (group with T10)
  - Message: `feat(scripts): add MySQL monitoring + visualization scripts`
  - Files: `scripts/visualization/*`

- [ ] 12. 벤치마크 오케스트레이션 러너 (Master Script)

  **What to do**:
  - `scripts/run_benchmark.sh` 작성 — 전체 벤치마크 시퀀스를 하나의 스크립트로 실행
  - CLI 인자: `--target` (aurora|oci), `--host`, `--port`, `--user`, `--password`, `--db`, `--output-dir`, `--skip-prepare` (데이터 이미 로드된 경우), `--skip-hammerdb`
  - 실행 순서:
    1. 환경 검증: sysbench, mysql, python3 설치 확인. HammerDB는 `--skip-hammerdb` 아닌 경우만
    2. 결과 디렉토리 생성: `{output-dir}/{target}_{timestamp}/`
    3. 모니터링 시작: `python3 monitor.py --daemon` 백그라운드 실행, PID 저장
    4. Sysbench prepare (skip 가능)
    5. Sysbench 스파이크 벤치마크 실행 (`run_spike_benchmark.sh` 호출)
    6. HammerDB TPC-C 실행 (`run_hammerdb.sh` 호출, skip 가능)
    7. 모니터링 종료: 저장된 PID로 kill
    8. Sysbench cleanup
    9. 결과 요약 출력: 각 단계 성공/실패, 결과 파일 경로
  - 각 단계 시작/종료 타임스탬프 로깅
  - 에러 발생 시 모니터링 프로세스 정리 후 종료 (trap)
  - `set -euo pipefail` + trap cleanup

  **Must NOT do**:
  - 양쪽(Aurora+OCI) 동시 실행 (한 번에 한 타겟만)
  - 시각화 실행 (별도 수동 실행)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 다단계 오케스트레이션, 프로세스 관리, 에러 핸들링
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3
  - **Blocks**: Tasks 17, 18, 19
  - **Blocked By**: Tasks 8, 9, 10

  **References**:

  **Pattern References**:
  - Task 8의 `run_spike_benchmark.sh` — sysbench 실행 인터페이스
  - Task 9의 `run_hammerdb.sh` — HammerDB 실행 인터페이스
  - Task 10의 `monitor.py --daemon` — 백그라운드 모니터링

  **WHY Each Reference Matters**:
  - 각 하위 스크립트의 CLI 인터페이스를 정확히 호출해야 함 → Task 8, 9, 10의 인자 형식 참조
  - trap으로 모니터링 프로세스 정리 필수 → 좀비 프로세스 방지

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: shellcheck 통과
    Tool: Bash
    Steps:
      1. shellcheck scripts/run_benchmark.sh
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-12-shellcheck.txt

  Scenario: CLI help 출력
    Tool: Bash
    Steps:
      1. bash scripts/run_benchmark.sh --help 2>&1
    Expected Result: --target, --host, --output-dir, --skip-prepare, --skip-hammerdb 옵션 설명
    Evidence: .sisyphus/evidence/task-12-help.txt

  Scenario: trap 설정 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "trap" scripts/run_benchmark.sh
    Expected Result: 1 이상 (cleanup trap 존재)
    Evidence: .sisyphus/evidence/task-12-trap.txt
  ```

  **Commit**: YES
  - Message: `feat(scripts): add benchmark orchestration runner + OS tuning`
  - Files: `scripts/run_benchmark.sh`, `scripts/os_tuning.sh`

- [ ] 13. OS 튜닝 스크립트 (클라이언트 VM용)

  **What to do**:
  - `scripts/os_tuning.sh` 작성 — 벤치마크 클라이언트 VM에서 실행
  - 튜닝 항목:
    - `ulimit -n 65535` (파일 디스크립터)
    - `sysctl -w net.ipv4.tcp_max_syn_backlog=65535`
    - `sysctl -w net.core.somaxconn=65535`
    - `sysctl -w net.ipv4.tcp_tw_reuse=1`
    - `sysctl -w net.ipv4.ip_local_port_range="1024 65535"` (ephemeral port 확장)
    - `sysctl -w vm.swappiness=1` (스왑 최소화)
  - `/etc/security/limits.conf`에 영구 설정 추가 옵션 (`--persist` 플래그)
  - 현재 설정값 출력 (before/after 비교)
  - root 권한 확인 (sudo 필요)

  **Must NOT do**:
  - 커널 파라미터 외 다른 시스템 설정 변경
  - 재부팅 요구

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: 단순 sysctl 명령어 나열, 짧은 스크립트
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 14)
  - **Blocks**: Task 16
  - **Blocked By**: None

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: shellcheck 통과
    Tool: Bash
    Steps:
      1. shellcheck scripts/os_tuning.sh
    Expected Result: exit code 0
    Evidence: .sisyphus/evidence/task-13-shellcheck.txt

  Scenario: 필수 sysctl 항목 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "tcp_max_syn_backlog\|somaxconn\|tcp_tw_reuse\|ip_local_port_range\|ulimit" scripts/os_tuning.sh
    Expected Result: 5 이상
    Evidence: .sisyphus/evidence/task-13-sysctl.txt
  ```

  **Commit**: YES (group with T12)
  - Message: `feat(scripts): add benchmark orchestration runner + OS tuning`
  - Files: `scripts/os_tuning.sh`

- [ ] 14. README + 실행 가이드

  **What to do**:
  - `README.md` 작성 (한국어)
  - 섹션:
    1. **프로젝트 개요**: 가설 요약, 비교 대상, 핵심 메트릭
    2. **아키텍처**: AWS/OCI 인프라 다이어그램 (ASCII art), 인스턴스 스펙 표
    3. **사전 요구사항**: Terraform, AWS CLI, OCI CLI, SSH 키, 계정 권한
    4. **인프라 프로비저닝**: `terraform init/plan/apply` 순서 (AWS → OCI)
    5. **벤치마크 클라이언트 설정**: SSH 접속 → OS 튜닝 → sysbench/HammerDB 설치 명령어
    6. **벤치마크 실행**: `run_benchmark.sh` 사용법, 각 단계 설명
    7. **결과 시각화**: `visualize.py` 사용법
    8. **정리**: `terraform destroy` 순서
    9. **파라미터 참조**: Aurora vs OCI MySQL 설정값 비교 표
  - 디렉토리 구조 트리 포함
  - sysbench/HammerDB 설치 명령어 (apt-get 기반)

  **Must NOT do**:
  - 영문 작성 (한국어로)
  - 벤치마크 결과 포함 (아직 실행 전)

  **Recommended Agent Profile**:
  - **Category**: `writing`
    - Reason: 문서 작성, 구조화된 가이드
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Tasks 12, 13)
  - **Blocks**: None
  - **Blocked By**: Tasks 1-13 (모든 코드 완성 후 정확한 문서 작성)

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: README 필수 섹션 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "프로젝트 개요\|사전 요구사항\|인프라 프로비저닝\|벤치마크 실행\|결과 시각화\|정리" README.md
    Expected Result: 6 이상
    Evidence: .sisyphus/evidence/task-14-readme-sections.txt

  Scenario: 디렉토리 구조 포함 확인
    Tool: Bash (grep)
    Steps:
      1. grep -c "terraform/aws\|terraform/oci\|scripts/sysbench\|scripts/hammerdb\|scripts/monitoring\|scripts/visualization" README.md
    Expected Result: 6 이상
    Evidence: .sisyphus/evidence/task-14-directory-tree.txt
  ```

  **Commit**: YES
  - Message: `docs: add README with setup and execution guide`
  - Files: `README.md`

- [ ] 15. Terraform Apply (AWS + OCI) + 연결 검증

  **What to do**:
  - 유저로부터 AWS 크레덴셜 + OCI 인증정보 수령
  - `terraform.tfvars` 작성 (양쪽)
  - AWS: `cd terraform/aws && terraform init && terraform plan && terraform apply -auto-approve`
  - OCI: `cd terraform/oci && terraform init && terraform plan && terraform apply -auto-approve`
  - 연결 검증:
    - AWS EC2 public IP로 SSH 접속 확인
    - EC2에서 Aurora endpoint로 `mysql -h <endpoint> -u admin -p -e "SELECT VERSION(); SHOW VARIABLES LIKE 'max_connections'; SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"`
    - OCI Compute public IP로 SSH 접속 확인
    - Compute에서 MDS endpoint로 `mysql -h <endpoint> -u admin -p -e "SELECT VERSION(); SHOW VARIABLES LIKE 'thread_pool%'; SHOW VARIABLES LIKE 'max_connections'; SHOW VARIABLES LIKE 'innodb_buffer_pool_size';"`
  - OCI thread pool 설정 검증: `thread_pool_size=16`, `thread_pool_max_transactions_limit=512` 확인
  - 양쪽 `max_connections=5000`, `innodb_buffer_pool_size` ~96GB 확인

  **Must NOT do**:
  - terraform.tfvars를 git에 커밋
  - 프로덕션 환경에 영향

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 크로스 클라우드 프로비저닝, 연결 검증, 트러블슈팅 가능성
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (순차: AWS → OCI → 검증)
  - **Parallel Group**: Wave 4
  - **Blocks**: Task 16
  - **Blocked By**: Tasks 4, 5, 6, 7

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: AWS Terraform apply 성공
    Tool: Bash
    Steps:
      1. cd terraform/aws && terraform apply -auto-approve
      2. terraform output -json
    Expected Result: Apply complete, outputs에 cluster_endpoint, client_public_ip 존재
    Evidence: .sisyphus/evidence/task-15-aws-apply.txt

  Scenario: OCI Terraform apply 성공
    Tool: Bash
    Steps:
      1. cd terraform/oci && terraform apply -auto-approve
      2. terraform output -json
    Expected Result: Apply complete, outputs에 db_endpoint, client_public_ip 존재
    Evidence: .sisyphus/evidence/task-15-oci-apply.txt

  Scenario: Aurora MySQL 연결 + 파라미터 확인
    Tool: Bash (SSH → mysql)
    Steps:
      1. ssh -i key.pem ubuntu@<ec2_ip> "mysql -h <aurora_endpoint> -u admin -p<password> -e \"SELECT VERSION(); SHOW VARIABLES LIKE 'max_connections';\""
    Expected Result: MySQL 8.0.x 버전, max_connections=5000
    Evidence: .sisyphus/evidence/task-15-aurora-connect.txt

  Scenario: OCI MySQL MDS 연결 + Thread Pool 확인
    Tool: Bash (SSH → mysql)
    Steps:
      1. ssh -i key.pem opc@<oci_ip> "mysql -h <mds_endpoint> -u admin -p<password> -e \"SHOW VARIABLES LIKE 'thread_pool%';\""
    Expected Result: thread_pool_size=16, thread_pool_max_transactions_limit=512
    Evidence: .sisyphus/evidence/task-15-oci-threadpool.txt
  ```

  **Commit**: NO (tfvars는 커밋하지 않음)

- [ ] 16. SSH 접속 → 벤치마크 도구 설치 + OS 튜닝 (양쪽 VM)

  **What to do**:
  - AWS EC2 SSH 접속 후:
    - `sudo bash scripts/os_tuning.sh` 실행
    - sysbench 설치: `sudo apt-get update && sudo apt-get install -y sysbench mysql-client python3-pip`
    - `pip3 install mysql-connector-python matplotlib numpy`
    - HammerDB 설치: 공식 릴리스 다운로드 + 설치
    - 스크립트 파일 전송 (scp 또는 git clone)
  - OCI Compute SSH 접속 후:
    - 동일 설치 과정 (Oracle Linux의 경우 `yum`/`dnf` 사용)
    - `sudo bash scripts/os_tuning.sh` 실행
    - sysbench, mysql-client, python3, HammerDB 설치
    - 스크립트 파일 전송
  - 설치 검증: `sysbench --version`, `hammerdbcli --version`, `python3 --version`, `mysql --version`

  **Must NOT do**:
  - DB 서버에 직접 접속하여 설정 변경 (Terraform으로 관리)
  - 불필요한 패키지 설치

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: SSH 접속, 크로스 OS 패키지 관리 (Ubuntu vs Oracle Linux), 트러블슈팅
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (AWS VM과 OCI VM 동시 설정 가능)
  - **Parallel Group**: Wave 4
  - **Blocks**: Tasks 17, 18, 19
  - **Blocked By**: Tasks 13, 15

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: AWS EC2 도구 설치 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "sysbench --version && python3 --version && mysql --version"
    Expected Result: 각 도구 버전 출력
    Evidence: .sisyphus/evidence/task-16-aws-tools.txt

  Scenario: OCI Compute 도구 설치 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh opc@<oci_ip> "sysbench --version && python3 --version && mysql --version"
    Expected Result: 각 도구 버전 출력
    Evidence: .sisyphus/evidence/task-16-oci-tools.txt

  Scenario: OS 튜닝 적용 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "ulimit -n && sysctl net.core.somaxconn net.ipv4.ip_local_port_range"
    Expected Result: ulimit=65535, somaxconn=65535, port_range="1024 65535"
    Evidence: .sisyphus/evidence/task-16-os-tuning.txt
  ```

  **Commit**: NO (원격 서버 작업)

- [ ] 17. Sysbench 벤치마크 실행 (Aurora)

  **What to do**:
  - AWS EC2에 SSH 접속
  - `bash run_benchmark.sh --target aurora --host <aurora_endpoint> --port 3306 --user admin --password <pw> --db benchmark --output-dir ./results/aurora`
  - 실행 내용 (오케스트레이션 스크립트가 자동 수행):
    1. 모니터링 시작
    2. Sysbench prepare (10 tables × 10M rows)
    3. 단계별 스파이크: 32→4096 threads, 각 3회 반복, 60초/회, 워밍업 60초
    4. Pareto 분포 테스트: 4096 threads, 120초
    5. 커스텀 Lua 티켓팅 테스트: 단계별 threads
    6. 모니터링 종료
    7. Sysbench cleanup
  - 예상 소요 시간: ~3-4시간
  - 결과 파일 확인: `results/aurora/` 하위에 로그 + CSV

  **Must NOT do**:
  - OCI 벤치마크 동시 실행 (순차 또는 별도 세션)
  - 벤치마크 중 DB 파라미터 변경

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 장시간 실행, 중간 모니터링, 에러 대응
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (Task 18과 병렬 가능 — 서로 다른 VM)
  - **Parallel Group**: Wave 4 (with Task 18)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 12, 16

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Sysbench 결과 파일 존재
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "ls results/aurora/*_4096t_run*.log | wc -l"
    Expected Result: 3 이상 (4096 threads × 3회 반복)
    Evidence: .sisyphus/evidence/task-17-result-files.txt

  Scenario: 모니터링 CSV 존재
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "head -5 results/aurora/monitor_*.csv"
    Expected Result: CSV 헤더 + 데이터 행 존재
    Evidence: .sisyphus/evidence/task-17-monitor-csv.txt

  Scenario: 에러율 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "grep 'err/s' results/aurora/*_32t_run1.log | tail -1"
    Expected Result: err/s 값 확인 가능 (0.00 이상)
    Evidence: .sisyphus/evidence/task-17-error-rate.txt
  ```

  **Commit**: NO (원격 서버 실행 결과)

- [ ] 18. Sysbench 벤치마크 실행 (OCI MDS)

  **What to do**:
  - OCI Compute에 SSH 접속
  - `bash run_benchmark.sh --target oci --host <mds_endpoint> --port 3306 --user admin --password <pw> --db benchmark --output-dir ./results/oci`
  - Task 17과 동일한 벤치마크 시퀀스 실행
  - OCI 추가 확인: 모니터링에서 `--thread-pool` 플래그 활성화하여 thread pool 메트릭 수집
  - 예상 소요 시간: ~3-4시간

  **Must NOT do**:
  - thread_pool_max_transactions_limit 값 변경 (512 고정)
  - Aurora 벤치마크와 다른 파라미터 사용

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: 장시간 실행, thread pool 메트릭 추가 수집
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (Task 17과 병렬 — 서로 다른 클라우드)
  - **Parallel Group**: Wave 4 (with Task 17)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 12, 16

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: Sysbench 결과 파일 존재
    Tool: Bash (SSH)
    Steps:
      1. ssh opc@<oci_ip> "ls results/oci/*_4096t_run*.log | wc -l"
    Expected Result: 3 이상
    Evidence: .sisyphus/evidence/task-18-result-files.txt

  Scenario: Thread pool 메트릭 수집 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh opc@<oci_ip> "head -5 results/oci/monitor_*.csv | grep -i thread"
    Expected Result: thread pool 관련 컬럼 존재
    Evidence: .sisyphus/evidence/task-18-threadpool-metrics.txt
  ```

  **Commit**: NO (원격 서버 실행 결과)

- [ ] 19. HammerDB TPC-C 실행 (Aurora + OCI)

  **What to do**:
  - AWS EC2에서: `bash run_hammerdb.sh --host <aurora_endpoint> --port 3306 --user admin --password <pw> --vu-list "8,16,32,64,128,256,512" --output-dir ./results/aurora/hammerdb`
  - OCI Compute에서: 동일 명령 (OCI endpoint)
  - 각 VU 수에서 10분 측정, 2분 워밍업
  - NOPM (New Orders Per Minute) 결과 수집
  - 예상 소요 시간: 각 ~2시간

  **Must NOT do**:
  - Sysbench와 동시 실행 (DB 부하 간섭)
  - warehouse 수 변경 (100 고정)

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: HammerDB 실행 + 결과 수집 + 트러블슈팅
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (Aurora와 OCI 동시 실행 가능)
  - **Parallel Group**: Wave 4 (after T17, T18)
  - **Blocks**: Task 20
  - **Blocked By**: Tasks 12, 16

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: HammerDB 결과 파일 존재
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "ls results/aurora/hammerdb/*_512vu.log"
    Expected Result: 파일 존재
    Evidence: .sisyphus/evidence/task-19-hammerdb-aurora.txt

  Scenario: NOPM 결과 확인
    Tool: Bash (SSH)
    Steps:
      1. ssh ubuntu@<ec2_ip> "grep -i 'NOPM' results/aurora/hammerdb/*_64vu.log"
    Expected Result: NOPM 수치 포함
    Evidence: .sisyphus/evidence/task-19-nopm.txt
  ```

  **Commit**: NO (원격 서버 실행 결과)

- [ ] 20. 결과 수집 + 시각화 + 보고서 생성

  **What to do**:
  - 양쪽 VM에서 결과 파일 로컬로 다운로드 (scp):
    - `scp -r ubuntu@<ec2_ip>:results/aurora/ ./results/aurora/`
    - `scp -r opc@<oci_ip>:results/oci/ ./results/oci/`
  - 시각화 실행:
    - `python3 scripts/visualization/visualize.py --aurora-dir ./results/aurora --oci-dir ./results/oci --output-dir ./reports/charts`
  - 생성되는 차트:
    1. TPS vs Thread Count (TPS cliff 비교) — 핵심 차트
    2. Latency Percentiles (p50/p95/p99) vs Thread Count
    3. TPS Time Series (4096 threads 구간)
    4. Error Rate vs Thread Count
    5. Monitoring Overlay (Threads_running + row lock waits)
  - 기술 보고서 초안 작성 (마크다운):
    - 가설 요약, 환경 설정, 벤치마크 방법론, 결과 차트 + 해석, 결론
  - 차트 PNG + 보고서를 `reports/` 디렉토리에 저장

  **Must NOT do**:
  - 결과 조작/선택적 보고
  - Aurora에 불리한 해석만 강조 (공정한 분석)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: 데이터 수집 + 시각화 실행 + 보고서 작성
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (마지막)
  - **Blocks**: F1-F4
  - **Blocked By**: Tasks 11, 17, 18, 19

  **Acceptance Criteria**:

  **QA Scenarios (MANDATORY):**

  ```
  Scenario: 차트 PNG 파일 생성 확인
    Tool: Bash
    Steps:
      1. ls reports/charts/*.png | wc -l
    Expected Result: 5 이상 (5개 차트)
    Evidence: .sisyphus/evidence/task-20-charts.txt

  Scenario: TPS cliff 차트에 양쪽 데이터 포함
    Tool: Bash
    Steps:
      1. python3 -c "from PIL import Image; img=Image.open('reports/charts/tps_vs_threads.png'); print(f'{img.size}')" 2>&1 || echo "Chart exists: $(test -f reports/charts/tps_vs_threads.png && echo YES || echo NO)"
    Expected Result: 차트 파일 존재 확인
    Evidence: .sisyphus/evidence/task-20-tps-chart.txt

  Scenario: 보고서 파일 존재
    Tool: Bash
    Steps:
      1. test -f reports/benchmark_report.md && wc -l reports/benchmark_report.md
    Expected Result: 파일 존재, 100줄 이상
    Evidence: .sisyphus/evidence/task-20-report.txt
  ```

  **Commit**: YES
  - Message: `feat(reports): add benchmark results and analysis report`
  - Files: `reports/*`

---

## Final Verification Wave (MANDATORY — after ALL implementation tasks)

> 4 review agents run in PARALLEL. ALL must APPROVE. Present consolidated results to user and get explicit "okay" before completing.

- [ ] F1. **Plan Compliance Audit** — `oracle`
  Read the plan end-to-end. For each "Must Have": verify implementation exists. For each "Must NOT Have": search codebase for forbidden patterns. Check evidence files exist in .sisyphus/evidence/. Compare deliverables against plan.
  Output: `Must Have [N/N] | Must NOT Have [N/N] | Tasks [N/N] | VERDICT: APPROVE/REJECT`

- [ ] F2. **Code Quality Review** — `unspecified-high`
  Run `terraform validate` on both modules. Run `shellcheck` on all .sh files. Run `python3 -m py_compile` on all .py files. Check for hardcoded credentials, empty error handling, unused variables.
  Output: `Terraform [PASS/FAIL] | Shell [PASS/FAIL] | Python [PASS/FAIL] | VERDICT`

- [ ] F3. **Real Manual QA** — `unspecified-high`
  Verify Terraform plan output shows correct resources. Verify sysbench scripts accept parameterized inputs. Verify monitoring script outputs correct CSV format. Verify visualization script can parse sample data.
  Output: `Scenarios [N/N pass] | Integration [N/N] | VERDICT`

- [ ] F4. **Scope Fidelity Check** — `deep`
  For each task: read "What to do", read actual files. Verify 1:1 — everything in spec was built, nothing beyond spec was built. Check "Must NOT do" compliance. Flag unaccounted changes.
  Output: `Tasks [N/N compliant] | Unaccounted [CLEAN/N files] | VERDICT`

---

## Commit Strategy

1. `feat(aws): add VPC, Aurora MySQL, EC2 client Terraform module` — terraform/aws/*
2. `feat(oci): add VCN, MySQL MDS with thread pool, Compute client Terraform module` — terraform/oci/*
3. `feat(scripts): add sysbench benchmark scripts (oltp spike + ticketing Lua)` — scripts/sysbench/*
4. `feat(scripts): add HammerDB TPC-C automation` — scripts/hammerdb/*
5. `feat(scripts): add MySQL monitoring + visualization scripts` — scripts/monitoring/*, scripts/visualization/*
6. `feat(scripts): add benchmark orchestration runner + OS tuning` — scripts/run_benchmark.sh, scripts/os_tuning.sh
7. `docs: add README with setup and execution guide` — README.md

---

## Success Criteria

### Verification Commands
```bash
cd terraform/aws && terraform init && terraform validate  # Expected: Success
cd terraform/oci && terraform init && terraform validate  # Expected: Success
shellcheck scripts/**/*.sh                                # Expected: exit 0
python3 -m py_compile scripts/monitoring/monitor.py       # Expected: exit 0
python3 -m py_compile scripts/visualization/visualize.py  # Expected: exit 0
```

### Final Checklist
- [ ] All "Must Have" present
- [ ] All "Must NOT Have" absent
- [ ] Terraform validate passes both modules
- [ ] All scripts pass syntax checks
- [ ] README documents full execution flow
