# Aurora MySQL vs OCI MySQL MDS 벤치마크

## 프로젝트 개요

이 프로젝트는 **AWS Aurora MySQL**과 **OCI MySQL MDS Enterprise** 간의 스파이크 트래픽 방어 능력을 비교 검증합니다.

핵심 가설: OCI MySQL MDS의 `thread_pool_max_transactions_limit` 파라미터가 커넥션 폭증 상황에서 Aurora MySQL 대비 더 안정적인 처리량과 지연 시간을 제공한다.

Aurora MySQL은 자체 Adaptive 커넥션 관리를 제공하지만 `thread_pool_max_transactions_limit` 같은 명시적 동시 트랜잭션 상한 설정을 지원하지 않습니다. OCI MySQL MDS Enterprise Thread Pool은 이 파라미터를 통해 동시 실행 트랜잭션 수를 512개로 제한하고, 초과 요청은 큐잉하여 DB 과부하를 방지합니다.

벤치마크 도구로는 sysbench (OLTP 스파이크 + 티켓팅 워크로드)와 HammerDB (TPC-C)를 사용합니다.

---

## 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│  AWS                                                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  VPC (10.0.0.0/16)                                       │  │
│  │                                                          │  │
│  │  ┌─────────────────────┐    ┌────────────────────────┐  │  │
│  │  │  EC2 Client          │    │  Aurora MySQL          │  │  │
│  │  │  c6i.4xlarge         │───>│  db.r6g.4xlarge        │  │  │
│  │  │  (16 vCPU, 32GB)     │    │  (16 vCPU, 128GB)      │  │  │
│  │  │                      │    │  Writer + Reader        │  │  │
│  │  │  sysbench / HammerDB │    │  Cluster Endpoint       │  │  │
│  │  └─────────────────────┘    └────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│  OCI                                                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  VCN (10.1.0.0/16)                                       │  │
│  │                                                          │  │
│  │  ┌─────────────────────┐    ┌────────────────────────┐  │  │
│  │  │  Compute Client      │    │  MySQL MDS             │  │  │
│  │  │  VM.Standard.E4.Flex │───>│  MySQL.16 (ECPU)       │  │  │
│  │  │  (16 OCPU, 32GB)     │    │  (16 ECPU, 128GB)      │  │  │
│  │  │                      │    │  Enterprise Thread Pool │  │  │
│  │  │  sysbench / HammerDB │    │  thread_pool_max_trx=512│  │  │
│  │  └─────────────────────┘    └────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘

벤치마크 흐름:
  Client VM
    └── sysbench / HammerDB
          ├── 준비 단계: 스키마 생성 + 데이터 로드
          ├── 워밍업: 정상 부하 (64 threads, 5분)
          ├── 스파이크: 급격한 커넥션 증가 (512\~2000 threads)
          └── 회복: 부하 감소 후 안정화 측정
```

---

## 인스턴스 스펙 비교

| 항목 | Aurora MySQL | OCI MySQL MDS |
|------|-------------|---------------|
| 인스턴스 | db.r6g.4xlarge | MySQL.16 (ECPU) |
| vCPU | 16 | 16 ECPU |
| 메모리 | 128GB | 128GB |
| max_connections | 5000 | 5000 |
| innodb_buffer_pool_size | \~96GB | 96GB |
| Thread Pool | Aurora Adaptive (제한적) | Enterprise Thread Pool |
| thread_pool_max_transactions_limit | 미지원 | 512 |
| 스토리지 | Aurora Distributed (자동 확장) | Block Volume |
| 리전 | ap-northeast-2 (서울) | ap-seoul-1 (서울) |

---

## 디렉토리 구조

```
.
├── terraform/
│   ├── aws/                    # VPC, Aurora 클러스터, EC2 클라이언트
│   │   ├── providers.tf
│   │   ├── variables.tf
│   │   ├── vpc.tf
│   │   ├── security_groups.tf
│   │   ├── aurora.tf
│   │   ├── parameter_groups.tf
│   │   ├── ec2_client.tf
│   │   ├── ssh_key.tf
│   │   ├── data.tf
│   │   ├── outputs.tf
│   │   └── terraform.tfvars.example
│   └── oci/                    # VCN, MySQL MDS, Compute 클라이언트
│       ├── providers.tf
│       ├── variables.tf
│       ├── vcn.tf
│       ├── nsg.tf
│       ├── mysql.tf
│       ├── mysql_config.tf
│       ├── compute_client.tf
│       ├── ssh_key.tf
│       ├── data.tf
│       ├── outputs.tf
│       └── terraform.tfvars.example
├── scripts/
│   ├── sysbench/
│   │   ├── run_spike_benchmark.sh   # OLTP 스파이크 러너
│   │   └── ticketing_workload.lua   # 티켓팅 시나리오 Lua 스크립트
│   ├── hammerdb/
│   │   ├── run_hammerdb.sh          # TPC-C 자동화 셸
│   │   ├── tpcc_build.tcl           # 스키마 빌드 TCL
│   │   └── tpcc_run.tcl             # TPC-C 실행 TCL
│   ├── monitoring/
│   │   ├── monitor.py               # MySQL 메트릭 수집기
│   │   └── requirements.txt
│   ├── visualization/
│   │   ├── visualize.py             # matplotlib 차트 생성
│   │   └── requirements.txt
│   ├── run_benchmark.sh             # 마스터 오케스트레이터
│   └── os_tuning.sh                 # 클라이언트 VM OS 튜닝
├── reports/
│   ├── benchmark_report.md          # 벤치마크 결과 보고서
│   └── charts/                      # 시각화 차트 (PNG)
├── REPORT.md                        # 루트 보고서 (차트 포함)
└── README.md
```

---

## 사전 요구사항

### 도구

- Terraform >= 1.5
- AWS CLI (configured, `aws configure` 완료)
- OCI CLI (configured, `~/.oci/config` 설정 완료)
- SSH 키 페어 (AWS EC2 및 OCI Compute 접속용)
- Python 3.8+

### 계정 권한

AWS:
- RDS: CreateDBCluster, CreateDBInstance, ModifyDBClusterParameterGroup
- EC2: RunInstances, CreateVpc, CreateSubnet, CreateSecurityGroup
- IAM: 위 서비스에 대한 충분한 권한

OCI:
- MySQL Database Service: manage mysql-family
- Compute: manage instance-family
- VCN: manage virtual-network-family
- 해당 Compartment에 대한 관리 권한

---

## 인프라 프로비저닝

### AWS

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 파일을 열어 필요한 값 입력
# (aws_region, key_name, db_password 등)
terraform init
terraform plan
terraform apply
```

완료 후 출력값에서 Aurora 엔드포인트와 EC2 퍼블릭 IP를 확인합니다.

### OCI

```bash
cd terraform/oci
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 파일을 열어 필요한 값 입력
# (tenancy_ocid, compartment_ocid, db_password 등)
terraform init
terraform plan
terraform apply
```

완료 후 출력값에서 MySQL MDS 엔드포인트와 Compute 퍼블릭 IP를 확인합니다.

---

## 벤치마크 클라이언트 설정

클라이언트 VM (EC2 또는 OCI Compute)에 SSH로 접속한 후 아래 순서로 설정합니다.

```bash
# 클라이언트 VM에 SSH 접속
ssh -i key.pem ubuntu@<ec2_public_ip>

# OS 튜닝 (커넥션 한도, 소켓 버퍼 등)
sudo bash scripts/os_tuning.sh

# sysbench 및 의존성 설치
sudo apt-get update && sudo apt-get install -y sysbench mysql-client python3-pip

# Python 라이브러리 설치
pip3 install mysql-connector-python matplotlib numpy

# HammerDB 설치 (선택 사항, TPC-C 벤치마크 시 필요)
wget https://github.com/TPC-Council/HammerDB/releases/download/v4.9/HammerDB-4.9-Linux.tar.gz
tar xzf HammerDB-4.9-Linux.tar.gz
```

---

## 벤치마크 실행

`run_benchmark.sh`는 전체 벤치마크 파이프라인을 순서대로 실행하는 마스터 스크립트입니다.

```bash
bash scripts/run_benchmark.sh \
  --target aurora \
  --host <aurora_endpoint> \
  --password <password> \
  --output-dir ./results
```

OCI 대상으로 실행할 때는 `--target oci`로 변경합니다.

실행 단계:

1. 준비 (Prepare): 스키마 생성 및 초기 데이터 로드
2. 워밍업 (Warmup): 64 threads로 5분간 정상 부하 인가, 버퍼 풀 워밍
3. 스파이크 (Spike): 커넥션 수를 단계적으로 512 -> 1000 -> 2000으로 증가시켜 스파이크 시뮬레이션
4. 회복 (Recovery): 부하를 정상 수준으로 낮추고 TPS/지연 시간 회복 속도 측정
5. 수집 (Collect): 각 단계별 TPS, 지연 시간(p95/p99), 에러율 JSON으로 저장

결과는 `--output-dir`에 타임스탬프 디렉토리로 저장됩니다.

---

## 결과 시각화

벤치마크 완료 후 아래 스크립트로 비교 차트를 생성합니다.

```bash
python3 scripts/visualization/visualize.py \
  --aurora-dir ./results/aurora_* \
  --oci-dir ./results/oci_* \
  --output-dir ./reports/charts
```

생성되는 차트:
- TPS 시계열 비교 (스파이크 구간 포함)
- p95 / p99 지연 시간 비교
- 에러율 비교
- 커넥션 수 대비 처리량 산점도

---

## 정리 (Teardown)

벤치마크 완료 후 과금 방지를 위해 인프라를 삭제합니다.

```bash
# AWS 리소스 삭제
cd terraform/aws
terraform destroy

# OCI 리소스 삭제
cd terraform/oci
terraform destroy
```

`terraform destroy` 실행 전 결과 파일을 로컬 또는 S3/Object Storage에 백업해 두세요.

---

## 파라미터 참조

### Aurora MySQL vs OCI MySQL MDS 주요 설정 비교

| 파라미터 | Aurora MySQL | OCI MySQL MDS | 비고 |
|---------|-------------|---------------|------|
| max_connections | 5000 | 5000 | 동일 |
| innodb_buffer_pool_size | \~96GB (자동) | 96GB | 메모리의 75% |
| innodb_io_capacity | 2000 | 2000 | |
| innodb_io_capacity_max | 4000 | 4000 | |
| innodb_flush_log_at_trx_commit | 1 | 1 | ACID 보장 |
| sync_binlog | 1 | 1 | ACID 보장 |
| thread_pool_size | N/A | 16 | OCPU 수와 동일 |
| thread_pool_max_transactions_limit | 미지원 | 512 | 핵심 차이점 |
| thread_pool_algorithm | N/A | 0 (default) | |
| thread_handling | one-thread-per-connection | pool-of-threads | |

### OCI MySQL MDS Thread Pool 상세 설정

| 파라미터 | 값 | 설명 |
|---------|-----|------|
| thread_pool_size | 16 | 스레드 풀 크기, OCPU 수와 동일하게 설정 |
| thread_pool_max_transactions_limit | 512 | 동시 실행 트랜잭션 상한. 초과 요청은 큐잉 처리 |
| thread_pool_algorithm | 0 | 기본 알고리즘 (high-concurrency 모드) |
| thread_pool_stall_limit | 100 | 스톨 감지 임계값 (ms) |
| thread_pool_idle_timeout | 60 | 유휴 스레드 타임아웃 (초) |

`thread_pool_max_transactions_limit = 512` 설정의 핵심 동작: 동시 실행 트랜잭션이 512개를 초과하면 신규 요청을 큐에 넣고 대기시킵니다. DB 내부 경합(lock contention, buffer pool pressure)을 줄여 스파이크 상황에서도 처리량 저하와 지연 시간 급증을 억제하는 것이 이 벤치마크의 검증 대상입니다.
