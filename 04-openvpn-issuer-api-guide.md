# 04. OpenVPN 자동 발급형 Issuer API 가이드

이 문서는 현재 운영형 기본 경로인 `NodeGroup-A / user script / 자동 발급 Issuer API`를 구축할 때 본다.

현재 기준 상태:

- 구현 및 검증 완료
  - `ta-sgh-ca`
  - `172.16.200.44:8443`
  - `Basic Auth -> node-token -> node-bundle`
  - 새 worker node scale-out 시 자동 발급 후 VPN 연결
- 확장 설계만 정리
  - `gateway-token -> gateway-bundle`
  - `workload-token -> workload-bundle`

표기 원칙:

- `템플릿`: endpoint, payload, 파일 경로를 일반화한 설명
- `실환경 예시`: 현재 `ta-sgh-ca`, `172.16.200.44:8443` 기준 값
- 이 문서는 가능하면 `템플릿 -> 실환경 예시` 순서로 유지한다

권장 순서:

1. `02-openvpn-nks-implementation-appendix.md`의 `5.1 ~ 5.8` 완료
2. `03-openvpn-server-build-guide.md`와 `02-openvpn-nks-implementation-appendix.md`의 `6장` 기준으로 OpenVPN 서버 검증
3. 이 문서의 `8장 ~ 14장`을 따라 `CA / Bootstrap Server`에 `Issuer API`를 구축
4. 다시 `02-openvpn-nks-implementation-appendix.md`의 `7.5`로 돌아가 `worker-egress` user script 경로를 검증

이 문서의 역할:

- `Issuer API`의 원리, endpoint, 신원 검증, 구현 기준을 설명한다
- `ta-sgh-ca`에 실제로 어떤 파일과 서비스가 올라가는지 정리한다
- worker 기준의 현재 표준 구현과 gateway/sidecar 확장 방향을 함께 설명한다

## 1. 자동 발급형 Issuer API 설계안

현재 worker 표준처럼 autoscale과 자동 발급까지 함께 가져가려면 `정적 bundle 저장소`만으로는 부족하다. 이때는 `고정된 Issuer API endpoint`가 `신원 검증 -> cert 발급 -> bundle packaging -> 응답`까지 수행하게 만든다.

구성:

```text
Offline Root CA
  -> Issuing CA 서명 / 교체용

Online Issuing CA
  -> 실제 client/server cert 발급

Issuer API
  -> caller 신원 검증
  -> CN / SAN 정책 적용
  -> Easy-RSA 또는 내부 signer 호출
  -> bundle 생성
  -> 응답 또는 저장소 업로드

CRL Publisher
  -> revoke 후 crl.pem 갱신
  -> OpenVPN Server / 배포 저장소 반영

Audit Log
  -> 발급 / 재발급 / 폐기 / 실패 이벤트 기록
```

공공기관/실운영 기준 원칙:

- `Offline Root CA`와 `Online Issuing CA`를 분리
- `Issuer API`는 `Private VPC` 내부에서만 노출
- `Issuer API`를 실제로 쓰려면 `CA / Bootstrap / Issuer` 서버 보안그룹에 `TCP/8443` inbound가 열려 있어야 함
- 발급 요청자는 반드시 식별 가능해야 함
- 발급/폐기 로그는 감사 가능한 형태로 남겨야 함
- `duplicate-cn`은 허용하지 않음

## 2. Issuer API endpoint 예시

| Endpoint | 호출 주체 | 용도 | 기본 응답 |
|---|---|---|---|
| `POST /v1/bootstrap/node-token` | `worker user script` | bootstrap credential과 metadata를 검증해 짧은 만료의 1회성 token 발급 | `JSON` |
| `POST /v1/bootstrap/node-bundle` | `worker user script` | 1회성 token을 소모하면서 node별 cert/bundle 발급 | `tar.gz` |
| `POST /v1/bootstrap/gateway-token` | `cloud-init`, `ansible`, 운영자 | gateway VM bootstrap credential과 metadata를 검증해 짧은 만료의 1회성 token 발급 | `JSON` |
| `POST /v1/bootstrap/gateway-bundle` | `cloud-init`, `ansible`, 운영자 | 1회성 token을 소모하면서 gateway VM cert/bundle 발급 | `tar.gz` |
| `POST /v1/bootstrap/workload-token` | CI, controller | workload 식별값을 검증해 짧은 만료의 1회성 token 발급 | `JSON` |
| `POST /v1/bootstrap/workload-bundle` | CI, controller | 1회성 token을 소모하면서 workload 단위 sidecar bundle 발급 | `JSON + secret payload` |
| `POST /v1/certs/revoke` | 운영자, 자동화 파이프라인 | cert 폐기 | `revoked=true` |
| `POST /v1/crl/publish` | 운영 파이프라인 | 새 `crl.pem` 배포 | `published=true` |

권장:

- `node/gateway`는 `bundle tar.gz` 직접 응답 또는 짧은 만료 `download_url`
- `sidecar`는 `JSON metadata + Secret 생성용 파일 세트` 반환이 다루기 쉽다
- `gateway/workload`도 `token -> bundle` 2단계 구조를 worker와 동일하게 맞추는 편이 운영 정합성이 높다

## 3. 요청/응답 예시

표기 방식:

- 아래 HTTP payload는 `실환경 예시`를 먼저 보여준다
- 실제 구축 시에는 `node_id`, `cluster`, `private_ip` 같은 값을 자기 환경값으로 치환한다
- 템플릿 관점에서는 `2장 endpoint`, `4장 신원 검증 방법`, `12장 서버 코드 예시`를 함께 본다

Node token 요청:

```http
POST /v1/bootstrap/node-token
Authorization: Basic <BASE64(bootstrap:password)>
Content-Type: application/json

{
  "node_id": "ta-sgh-pri-cls-default-worker-node-10",
  "node_group": "default-worker",
  "role": "worker",
  "cluster": "ta-sgh-pri-cls",
  "metadata": {
    "instance_id": "instance-default-worker-10",
    "local_hostname": "ta-sgh-pri-cls-default-worker-node-10",
    "private_ip": "172.16.200.55"
  }
}
```

Node token 응답:

```json
{
  "token": "auto-node-<RANDOM>",
  "expires_at": "2026-04-07T04:10:00Z",
  "subject": "ta-sgh-pri-cls-default-worker-node-10",
  "node_group": "default-worker",
  "cluster": "ta-sgh-pri-cls"
}
```

Node bundle 요청:

```http
POST /v1/bootstrap/node-bundle
Authorization: Bearer <ONE_TIME_NODE_TOKEN>
Content-Type: application/json

{
  "node_id": "ta-sgh-pri-cls-default-worker-node-10",
  "node_group": "default-worker",
  "role": "worker",
  "cluster": "ta-sgh-pri-cls",
  "metadata": {
    "instance_id": "instance-default-worker-10",
    "local_hostname": "ta-sgh-pri-cls-default-worker-node-10",
    "private_ip": "172.16.200.55"
  }
}
```

응답 예시 1. 직접 bundle 반환:

```http
200 OK
Content-Type: application/gzip
Content-Disposition: attachment; filename="ta-sgh-pri-cls-default-worker-node-10.tar.gz"
```

응답 예시 2. token 검증 실패:

```json
{
  "detail": "token already used"
}
```

Gateway VM 요청 형식 메모:

- `gateway-token`, `gateway-bundle`도 같은 2단계 구조를 쓴다.
- `node_id`, `node_group` 대신 `gateway_id`, `gateway_group`을 쓰고 `role`은 `gateway`로 둔다.
- metadata는 `instance_id`, `local_hostname`, `private_ip`를 같은 방식으로 유지하는 편이 운영 정합성이 높다.

Workload token 요청:

```http
POST /v1/bootstrap/workload-token
Authorization: Bearer <CI_OR_CONTROLLER_BOOTSTRAP_TOKEN>
Content-Type: application/json

{
  "namespace": "app-ns",
  "workload": "app1",
  "type": "deployment",
  "bundle_scope": "workload",
  "cluster": "ta-sgh-pri-cls"
}
```

Workload token 응답:

```json
{
  "token": "auto-workload-<RANDOM>",
  "expires_at": "2026-04-07T04:15:00Z",
  "subject": "app-ns/app1",
  "bundle_scope": "workload"
}
```

Workload bundle 요청:

```http
POST /v1/bootstrap/workload-bundle
Authorization: Bearer <ONE_TIME_WORKLOAD_TOKEN>
Content-Type: application/json

{
  "namespace": "app-ns",
  "workload": "app1",
  "type": "deployment",
  "bundle_scope": "workload",
  "cluster": "ta-sgh-pri-cls"
}
```

응답 예시:

```json
{
  "cn": "ovpn-pod-app-ns-app1-2026q2",
  "files": {
    "ca.crt": "<base64>",
    "client.crt": "<base64>",
    "client.key": "<base64>",
    "tls-crypt.key": "<base64>"
  }
}
```

## 4. 신원 검증 방법

Node / Gateway:

- 현재 서버 구현:
  - `Basic Auth bootstrap credential`
  - `metadata.local_hostname == node_id`
  - `metadata.private_ip == request.client.host`
  - `metadata.instance_id 존재`
  - 위 조건이 맞으면 runtime 1회성 token 발급
- gateway VM도 같은 패턴으로 확장하는 편이 맞다.
  - `gateway-token`: `Basic Auth + metadata`
  - `gateway-bundle`: 1회성 token 소모 + tar.gz 반환
- 다음 운영 강화안:
  - bootstrap용 mTLS cert
  - cloud metadata signed assertion
  - 사설망 IP + 추가 토큰 또는 별도 attestation

Sidecar / Workload:

- `CI/CD`가 Issuer API를 호출
- 또는 `cluster 내부 controller`가 `ServiceAccount`로 호출
- Pod가 직접 발급 API를 두드리게 하기보다는 `controller/CI` 경유가 더 안전하다
- 권장 패턴:
  - `workload-token`: CI 또는 controller bootstrap identity 검증
  - `workload-bundle`: 1회성 token 소모 + JSON files 반환

현재 구현 메모:

```bash
# worker node용 token은 미리 seed하지 않는다.
# /v1/bootstrap/node-token 호출 시 서버가 /opt/ovpn-issuer/tokens.json에
# 짧은 만료의 runtime 1회성 token을 자동으로 추가한다.
```

cluster 내부 controller 또는 운영 검증용 ServiceAccount token 예시:

```bash
kubectl -n app-ns create serviceaccount ovpn-issuer-caller
kubectl -n app-ns create token ovpn-issuer-caller
```

실무 메모:

- 현재 구현은 `반자동 seed token`이 아니라 `완전 자동 runtime token` 방식이다.
- 운영에서는 token 1회성 소모, 만료시각, 발급 이력, 호출자 IP를 유지하고 이후 mTLS나 signed metadata로 강화하는 편이 맞다.

## 5. 방안별 자동 발급 적용 방법

주 방안 / `User Script`:

```text
node boot
  -> user script
  -> POST /v1/bootstrap/node-token
  -> 1회성 node token 수신
  -> POST /v1/bootstrap/node-bundle
  -> node별 bundle 수신
  -> /etc/openvpn/client/pki 배치
  -> openvpn-client@worker-egress 시작
```

주 방안 / `직접 설치`:

```text
운영자
  -> bootstrap endpoint에서 공통 패키지 / bootstrap CA 준비
  -> POST /v1/bootstrap/node-token
  -> 1회성 node token 수신
  -> POST /v1/bootstrap/node-bundle
  -> 번들 수신
  -> 대상 node에 배포
  -> OpenVPN client 시작
```

메모:

- 현재 표준에서 `직접 설치`는 `User Script`와 다른 발급 체계를 쓰는 것이 아니라, `User Script`가 수행하는 `bootstrap CA 준비 -> runtime bundle 설치 -> node-token -> node-bundle -> OpenVPN client 기동`을 운영자가 수동으로 실행하는 방식이다.
- 현재 문서 기준의 표준 흐름은 `User Script`와 `직접 설치` 두 경로만 다룬다. 그 외 자동화 아이디어는 이 문서의 범위에 넣지 않는다.

추가 방안 1 / `Gateway VM`:

```text
gateway VM boot
  -> cloud-init 또는 ansible
  -> POST /v1/bootstrap/gateway-token
  -> POST /v1/bootstrap/gateway-bundle
  -> gateway별 bundle 수신
  -> OpenVPN client 시작
```

추가 방안 2 / `Sidecar`:

```text
CI 또는 controller
  -> POST /v1/bootstrap/workload-token
  -> POST /v1/bootstrap/workload-bundle
  -> workload별 bundle 수신
  -> Kubernetes Secret 갱신
  -> rollout restart
```

## 6. 폐기 / CRL 자동화 흐름

```text
운영자 또는 자동화 파이프라인
  -> POST /v1/certs/revoke
  -> CA에서 revoke 처리
  -> gen-crl
  -> POST /v1/crl/publish
  -> OpenVPN Server에 새 crl.pem 반영
  -> client 재접속 제어
```

권장:

- `node 폐기` 시 해당 cert 즉시 revoke
- `gateway 교체` 시 새 cert 발급 후 기존 cert revoke
- `workload sidecar`는 Secret 교체 후 구 cert revoke

최소 수동 절차:

```bash
cd /opt/easy-rsa
./easyrsa revoke <CN>
./easyrsa gen-crl
sudo install -m 0644 /opt/easy-rsa/pki/crl.pem /srv/bootstrap/ovpn/revoked/crl.pem
scp /opt/easy-rsa/pki/crl.pem ovpn-server:/tmp/crl.pem
ssh ovpn-server 'sudo install -m 0644 /tmp/crl.pem /etc/openvpn/server/pki/crl.pem && sudo systemctl restart openvpn-server@server'
```

최소 자동화 스크립트 예시:

```bash
#!/usr/bin/env bash
set -euo pipefail

CN="${1:?usage: revoke-and-publish.sh <cn>}"

cd /opt/easy-rsa
./easyrsa revoke "$CN"
./easyrsa gen-crl

sudo install -m 0644 pki/crl.pem /srv/bootstrap/ovpn/revoked/crl.pem
scp pki/crl.pem ovpn-server:/tmp/crl.pem
ssh ovpn-server 'sudo install -m 0644 /tmp/crl.pem /etc/openvpn/server/pki/crl.pem && sudo systemctl restart openvpn-server@server'
```

## 7. 자동 발급 구현 최소 기준

이 문서의 `Issuer API` 섹션은 인터페이스와 운영 원칙만 정의한 것이 아니다. 아래 배치, 디렉터리 구조, 패키지 설치, 예시 코드, systemd 서비스까지 따라가면 `PoC 수준의 자동 발급 API 서버`는 실제로 구현할 수 있다.

실제로 자동 발급이 동작하려면 최소 아래 4개가 있어야 한다.

- `신원 검증 수단`
  - `node/gateway`: 짧은 만료 bootstrap token, metadata 기반 1회성 토큰, 또는 bootstrap용 mTLS
  - `sidecar/workload`: CI 토큰 또는 cluster 내부 controller의 ServiceAccount
- `발급 실행기`
  - `issue-client-bundle.sh`를 호출해 cert/key/bundle을 만들고 `CN`, `TYPE`, 발급 시각을 로그에 남기는 API 또는 잡
- `bootstrap packages 저장소`
  - `/srv/bootstrap/ovpn/packages/`
  - `bootstrap-root-ca.pem`, `worker-egress-bootstrap.sh`, `node-runtime-ubuntu2204-amd64.tar.gz` 같은 공통 파일 제공
- `bundle 응답 방식`
  - 현재 worker 표준은 `node-bundle` 호출에 대한 `tar.gz 직접 응답`
  - `/srv/bootstrap/ovpn/issued/<ID>.tar.gz`는 fallback, 확장안, 수동 분석용으로만 선택적으로 남겨둘 수 있다
- `감사/폐기 연동`
  - 발급 성공/실패 로그
  - `revoke` 후 `crl.pem` 재배포

최소 PoC 흐름:

```text
node boot
  -> user script
  -> 고정 Issuer API 호출
  -> API가 token과 node_id 검증
  -> issue-client-bundle.sh <cn> node 실행
  -> 현재 worker 표준은 bundle을 직접 응답
  -> 선택적으로 /srv/bootstrap/ovpn/issued/<NODE_ID>.tar.gz fallback 저장 가능
  -> node가 bundle 수신 후 OpenVPN 기동
```

중요:

- 위 최소 구성 전까지는 `자동 발급`이 아니라 `사전 발급된 bundle 다운로드` 방식이다
- 과업 목표인 `curl google.com` 검증만 놓고 보면 `자동 발급`이 필수는 아니다
- 하지만 `autoscale 대응`까지 포함하면 `Issuer API` 또는 동등한 자동 발급 장치가 필요하다

## 8. 자동 발급 API 서버 권장 배치

중요:

- 아래는 자동 발급 API가 필요할 때 수행한다.
- 현재 문서 기준으로는 별도 `Issuer Host VM`을 만들지 않고, `CA / Bootstrap Server`에 `Issuer API 역할`을 추가 배치한다.

권장 배치:

```text
Private VPC
  +-----------------------------------------------+
  | CA / Bootstrap / Issuer Server                |
  | - Easy-RSA / pki                              |
  | - nginx bootstrap repo                        |
  | - Issuer API(FastAPI/Uvicorn)                 |
  | - /srv/bootstrap/ovpn/packages                |
  | - /srv/bootstrap/ovpn/issued (선택 fallback) |
  +-----------------------------------------------+
```

현재 문서 기준으로는 `Issuer Host`를 별도 인스턴스로 두지 않고, `CA / Bootstrap Server`와 같은 VM에서 운영한다.

운영 권장:

- 장기 운영에서 보안 분리가 더 중요해지면 `Issuer Host`와 `CA Server`를 분리할 수 있다
- 분리 시 `Issuer Host`는 signer wrapper만 호출
- `CA private key` 접근은 최소화

## 9. Issuer API 역할 디렉터리 구조

```text
/opt/ovpn-issuer/
  app.py
  tokens.json
  logs/
    issuer.log
  venv/

/opt/easy-rsa/
  easyrsa
  pki/
  scripts/
    issue-client-bundle.sh

/srv/bootstrap/ovpn/
  packages/
  issued/
  revoked/
```

메모:

- `packages/`는 현재 worker 표준에서 필수다.
- `issued/`는 정적 fallback, gateway/sidecar 확장, 수동 분석용으로만 남겨둘 수 있는 선택 경로다.

## 10. Issuer API 역할 패키지 설치

현재 서버 기준 권장 작업 위치:

- `ta-sgh-ovpn`
  - 인터넷 outbound가 되는 준비용 호스트
  - 다운로드 산출물 보관 경로: `~/pkg/issuer-host/`
- `ta-sgh-ca`
  - 실제 `Issuer API`를 올릴 `CA / Bootstrap Server`
  - 1차 반입 경로: `~/inbox/issuer-host/`
  - 실제 설치 캐시 경로: `/root/pkg/issuer-host/`
  - 실제 앱 경로: `/opt/ovpn-issuer/`

```bash
## 외부 다운로드 호스트 - apt 패키지
mkdir -p ~/pkg/issuer-host/debs
cd ~/pkg/issuer-host/debs

sudo apt-get update
sudo apt-get install -y apt-rdepends

apt-rdepends python3 python3-venv python3-pip jq 2>/dev/null \
  | grep -E '^[a-z0-9][a-z0-9.+-]*(:[a-z0-9]+)?$' \
  | sort -u > pkglist.raw

while read -r pkg; do
  if apt-cache show "$pkg" 2>/dev/null | grep -q '^Filename: '; then
    echo "$pkg"
  fi
done < pkglist.raw > pkglist.txt

xargs -a pkglist.txt sudo apt-get install --download-only --reinstall -y \
  -o Dir::Cache::archives="$(pwd)/"

tar czf ../issuer-host-debs.tar.gz ./*.deb

## 외부 다운로드 호스트 - Python wheel
cd ..
mkdir -p wheels
python3 -m pip download -d wheels fastapi uvicorn
tar czf issuer-host-wheels.tar.gz -C wheels .

## 준비 호스트 -> CA / Bootstrap Server 복사
ssh ta-sgh-ca 'mkdir -p ~/inbox/issuer-host'
scp ~/pkg/issuer-host/issuer-host-debs.tar.gz ta-sgh-ca:~/inbox/issuer-host/
scp ~/pkg/issuer-host/issuer-host-wheels.tar.gz ta-sgh-ca:~/inbox/issuer-host/

## CA / Bootstrap Server
cd ~/inbox/issuer-host
sudo install -d -m 0750 /root/pkg/issuer-host/debs
sudo install -d -m 0750 /root/pkg/issuer-host/wheels
sudo tar xzf ~/inbox/issuer-host/issuer-host-debs.tar.gz -C /root/pkg/issuer-host/debs
sudo tar xzf ~/inbox/issuer-host/issuer-host-wheels.tar.gz -C /root/pkg/issuer-host/wheels

sudo bash -lc 'dpkg -i /root/pkg/issuer-host/debs/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/issuer-host/debs --no-download -f install -y'

sudo install -d -m 0750 /opt/ovpn-issuer
sudo install -d -m 0750 /opt/ovpn-issuer/logs
sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo install -d -m 0750 /srv/bootstrap/ovpn/revoked

sudo python3 -m venv /opt/ovpn-issuer/venv
sudo /opt/ovpn-issuer/venv/bin/pip install --no-index --find-links=/root/pkg/issuer-host/wheels fastapi uvicorn
```

메모:

- 현재 실습 서버 기준으로는 `ta-sgh-ovpn`에서 패키지를 준비하고, `ta-sgh-ca`의 `~/inbox/issuer-host/`에 tarball 두 개만 반입한 뒤 설치하면 된다.
- `ta-sgh-ca`에서는 `~/inbox/issuer-host`가 작업용 반입 경로이고, `/root/pkg/issuer-host`는 실제 오프라인 설치 캐시 경로다.
- `Issuer API 역할`도 private 구간이면 인터넷 outbound가 없으므로 `pip install fastapi uvicorn`을 직접 치지 않는다.
- wheel 파일까지 외부에서 미리 받아와 `--no-index`로 설치해야 문서 전제가 맞다.
- 외부 다운로드 호스트에서 `python3 -m pip download`를 쓰려면 해당 호스트에는 최소 `python3-pip`가 준비돼 있어야 한다.

## 11. runtime 1회성 token 저장 형식

현재 `ta-sgh-ca`에 반영한 구현은 `사전 seed token`이 아니라 `node-token` 호출 시점에 생성되는 runtime 1회성 token이다.

구성:

- `scope=node`
- `subject=<NODE_ID>`
- `node_group`
- `cluster`
- `metadata.instance_id`
- `metadata.local_hostname`
- `metadata.private_ip`
- `expires_at`
- `used`
- `issued_at`
- `issued_by.client_ip`
- `issued_by.mode`

현재 서버 기준 파일:

`/opt/ovpn-issuer/tokens.json`

```json
{
  "tokens": {
    "auto-node-hoG4rdHdON-245qkeEL5628YCxfvZPfw": {
      "scope": "node",
      "subject": "issuer-auto-selftest-node-01",
      "node_group": "default-worker",
      "cluster": "ta-sgh-pri-cls",
      "metadata": {
        "instance_id": "instance-auto-selftest-001",
        "local_hostname": "issuer-auto-selftest-node-01",
        "private_ip": "172.16.200.44"
      },
      "expires_at": "2026-04-07T03:57:25.513057Z",
      "used": true,
      "issued_at": "2026-04-07T03:47:25.513250+00:00",
      "issued_by": {
        "client_ip": "172.16.200.44",
        "mode": "auto-basic-auth"
      },
      "used_at": "2026-04-07T03:47:25.680493+00:00",
      "used_by": {
        "client_ip": "172.16.200.44",
        "node_id": "issuer-auto-selftest-node-01",
        "node_group": "default-worker"
      }
    }
  }
}
```

운영형 전개 메모:

- 현재 `tokens.json`은 runtime 상태 저장소다.
- 운영에서는 별도 token 저장소나 DB로 바꾸는 편이 맞다.
- 그래도 검증 포인트는 같다.
  - metadata 일치
  - 만료 시각
  - 1회 사용 후 `used=true`
  - `issued_by`, `used_by` 감사 기록

## 12. Issuer API 서버 예시 코드

아래 예시는 현재 `ta-sgh-ca`에 반영한 `node-token -> node-bundle` 기준 최소 구현이다.

실제 경로:

- Easy-RSA 홈: `/home/ubuntu/easy-rsa`
- bundle script: `/home/ubuntu/easy-rsa/scripts/issue-client-bundle.sh`
- dist 경로: `/home/ubuntu/dist`
- bootstrap 저장소: `/srv/bootstrap/ovpn/issued`
- 앱 경로: `/opt/ovpn-issuer/app.py`

`/opt/ovpn-issuer/app.py`

```python
import base64
import binascii
import fcntl
import hmac
import json
import os
import secrets
import shutil
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel

APP = FastAPI()

TOKENS_FILE = Path('/opt/ovpn-issuer/tokens.json')
EASYRSA_HOME = Path('/home/ubuntu/easy-rsa')
ISSUE_SCRIPT = EASYRSA_HOME / 'scripts' / 'issue-client-bundle.sh'
DIST_HOME = Path('/home/ubuntu/dist')
BOOTSTRAP_DIR = Path('/srv/bootstrap/ovpn/issued')

ISSUER_BOOTSTRAP_USER = os.getenv('ISSUER_BOOTSTRAP_USER', '')
ISSUER_BOOTSTRAP_PASSWORD = os.getenv('ISSUER_BOOTSTRAP_PASSWORD', '')
ISSUER_TOKEN_TTL_SECONDS = int(os.getenv('ISSUER_TOKEN_TTL_SECONDS', '600'))


class NodeMetadata(BaseModel):
    instance_id: str
    local_hostname: str
    private_ip: str


class NodeBundleRequest(BaseModel):
    node_id: str
    node_group: str
    role: str
    cluster: str
    metadata: NodeMetadata


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def parse_timestamp(value: str) -> datetime:
    return datetime.fromisoformat(value.replace('Z', '+00:00'))


def node_cn(node_id: str) -> str:
    return node_id if node_id.startswith('ovpn-node-') else f'ovpn-node-{node_id}'


def ensure_token_store_exists() -> None:
    if not TOKENS_FILE.exists():
        TOKENS_FILE.write_text(json.dumps({'tokens': {}}, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def load_tokens_locked(fp) -> dict:
    fp.seek(0)
    raw = fp.read().strip()
    if not raw:
        return {'tokens': {}}
    return json.loads(raw)


def write_tokens_locked(fp, data: dict) -> None:
    fp.seek(0)
    json.dump(data, fp, ensure_ascii=False, indent=2)
    fp.write('\n')
    fp.truncate()


def parse_basic_authorization(authorization: str | None) -> tuple[str, str]:
    if not authorization or not authorization.startswith('Basic '):
        raise HTTPException(status_code=401, detail='missing basic auth')

    token = authorization.split(' ', 1)[1]
    try:
        decoded = base64.b64decode(token).decode('utf-8')
    except (binascii.Error, UnicodeDecodeError) as exc:
        raise HTTPException(status_code=401, detail='invalid basic auth') from exc

    if ':' not in decoded:
        raise HTTPException(status_code=401, detail='invalid basic auth')

    return decoded.split(':', 1)


def require_bootstrap_basic(authorization: str | None) -> None:
    user, password = parse_basic_authorization(authorization)

    if not ISSUER_BOOTSTRAP_USER or not ISSUER_BOOTSTRAP_PASSWORD:
        raise HTTPException(status_code=500, detail='issuer bootstrap credentials are not configured')

    if not hmac.compare_digest(user, ISSUER_BOOTSTRAP_USER) or not hmac.compare_digest(password, ISSUER_BOOTSTRAP_PASSWORD):
        raise HTTPException(status_code=403, detail='invalid bootstrap credentials')


def validate_node_request(req: NodeBundleRequest, client_ip: str) -> None:
    if req.role != 'worker':
        raise HTTPException(status_code=403, detail='role mismatch')
    if req.metadata.local_hostname != req.node_id:
        raise HTTPException(status_code=403, detail='local_hostname mismatch')
    if req.metadata.private_ip != client_ip:
        raise HTTPException(status_code=403, detail='private_ip mismatch')
    if not req.metadata.instance_id:
        raise HTTPException(status_code=403, detail='instance_id missing')


def issue_one_time_node_token(authorization: str | None, req: NodeBundleRequest, client_ip: str) -> dict:
    require_bootstrap_basic(authorization)
    validate_node_request(req, client_ip)
    ensure_token_store_exists()

    token = f'auto-node-{secrets.token_urlsafe(24)}'
    expires_at = (utcnow() + timedelta(seconds=ISSUER_TOKEN_TTL_SECONDS)).isoformat().replace('+00:00', 'Z')

    with TOKENS_FILE.open('r+', encoding='utf-8') as fp:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
        data = load_tokens_locked(fp)
        data.setdefault('tokens', {})[token] = {
            'scope': 'node',
            'subject': req.node_id,
            'node_group': req.node_group,
            'cluster': req.cluster,
            'metadata': {
                'instance_id': req.metadata.instance_id,
                'local_hostname': req.metadata.local_hostname,
                'private_ip': req.metadata.private_ip,
            },
            'expires_at': expires_at,
            'used': False,
            'issued_at': utcnow().isoformat(),
            'issued_by': {
                'client_ip': client_ip,
                'mode': 'auto-basic-auth',
            },
        }
        write_tokens_locked(fp, data)
        fcntl.flock(fp.fileno(), fcntl.LOCK_UN)

    return {
        'token': token,
        'expires_at': expires_at,
        'subject': req.node_id,
        'node_group': req.node_group,
        'cluster': req.cluster,
    }


def issue_node_bundle_with_token(authorization: str | None, req: NodeBundleRequest, client_ip: str) -> Path:
    if not authorization or not authorization.startswith('Bearer '):
        raise HTTPException(status_code=401, detail='missing bearer token')

    validate_node_request(req, client_ip)
    token = authorization.split(' ', 1)[1]
    cn = node_cn(req.node_id)
    ensure_token_store_exists()

    with TOKENS_FILE.open('r+', encoding='utf-8') as fp:
        fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
        data = load_tokens_locked(fp)
        tokens = data.setdefault('tokens', {})
        entry = tokens.get(token)

        if not entry:
            raise HTTPException(status_code=403, detail='invalid token')
        if entry.get('scope') != 'node':
            raise HTTPException(status_code=403, detail='scope mismatch')
        if entry.get('subject') != req.node_id:
            raise HTTPException(status_code=403, detail='subject mismatch')
        if entry.get('node_group') and entry['node_group'] != req.node_group:
            raise HTTPException(status_code=403, detail='node_group mismatch')
        if entry.get('cluster') and entry['cluster'] != req.cluster:
            raise HTTPException(status_code=403, detail='cluster mismatch')

        expected_md = entry.get('metadata', {})
        for key, expected in expected_md.items():
            actual = getattr(req.metadata, key, None)
            if actual != expected:
                raise HTTPException(status_code=403, detail=f'metadata mismatch: {key}')

        expires_at = entry.get('expires_at')
        if expires_at and utcnow() >= parse_timestamp(expires_at):
            raise HTTPException(status_code=403, detail='token expired')
        if entry.get('used'):
            raise HTTPException(status_code=409, detail='token already used')

        try:
            subprocess.run(
                [str(ISSUE_SCRIPT), cn, 'node'],
                cwd=str(EASYRSA_HOME),
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr.strip() or exc.stdout.strip() or 'bundle issuance failed'
            raise HTTPException(status_code=500, detail=detail) from exc

        bundle_tar = DIST_HOME / 'nodes' / f'{cn}.tar.gz'
        if not bundle_tar.exists():
            raise HTTPException(status_code=500, detail='bundle tarball not found')

        entry['used'] = True
        entry['used_at'] = utcnow().isoformat()
        entry['used_by'] = {
            'client_ip': client_ip,
            'node_id': req.node_id,
            'node_group': req.node_group,
        }

        write_tokens_locked(fp, data)
        fcntl.flock(fp.fileno(), fcntl.LOCK_UN)
        return bundle_tar


@APP.get('/healthz')
def healthz():
    return {'ok': True}


@APP.post('/v1/bootstrap/node-token')
def node_token(req: NodeBundleRequest, request: Request, authorization: str | None = Header(default=None)):
    payload = issue_one_time_node_token(authorization, req, request.client.host if request.client else 'unknown')
    return JSONResponse(payload)


@APP.post('/v1/bootstrap/node-bundle')
def node_bundle(req: NodeBundleRequest, request: Request, authorization: str | None = Header(default=None)):
    src = issue_node_bundle_with_token(authorization, req, request.client.host if request.client else 'unknown')
    dst = BOOTSTRAP_DIR / f'{req.node_id}.tar.gz'
    shutil.copy2(src, dst)
    return FileResponse(path=dst, filename=f'{req.node_id}.tar.gz', media_type='application/gzip')
```

현재 검증된 것:

- `GET /healthz` 정상
- `Basic Auth -> /v1/bootstrap/node-token -> 1회성 token 수신` 정상
- 같은 요청값으로 `/v1/bootstrap/node-bundle` 호출 후 `tar.gz` 응답 정상
- 신규 `node_id`에 대한 신규 cert 서명 정상
- 같은 1회성 token 재사용 시 `409 token already used` 정상

아직 남은 것:

- `gateway/workload` endpoint 확장
- bootstrap credential 강화를 위한 `mTLS` 또는 signed metadata
- 감사 로그 외부 적재

실무 메모:

- 신규 cert 서명을 자동화하려면 `ca.key` passphrase를 무인으로 공급할 방법이 필요하다.
- 현재 서버에는 `/etc/ovpn-issuer/issuer.env` 훅을 열어 두었다.
- 여기서 넣는 passphrase는 `Easy-RSA build-ca` 수행 시 직접 입력했던 `ca.key` passphrase를 넣어야 한다.
- 즉 `bootstrap Basic Auth 비밀번호`나 `OpenVPN client cert` 값이 아니라, `~/easy-rsa/pki/private/ca.key`를 여는 암호다.
- 현재 실습 서버에서는 `build-ca` 때 사용한 값으로 `tlsrlgh07`를 넣어 신규 node self-test까지 확인했다.
- 현재 실습 서버 기준 `issuer.env` 예시:

```bash
echo -n '<CA_KEY_PASSPHRASE_FROM_BUILD_CA>' | sudo tee /opt/ovpn-issuer/ca-key-passphrase >/dev/null
sudo chmod 0600 /opt/ovpn-issuer/ca-key-passphrase
cat <<'EOF' | sudo tee /etc/ovpn-issuer/issuer.env >/dev/null
EASYRSA_PASSIN=file:/opt/ovpn-issuer/ca-key-passphrase
ISSUER_BOOTSTRAP_USER=bootstrap
ISSUER_BOOTSTRAP_PASSWORD=<BOOTSTRAP_PASSWORD>
ISSUER_TOKEN_TTL_SECONDS=600
EOF
sudo chmod 0600 /etc/ovpn-issuer/issuer.env
sudo systemctl restart ovpn-issuer
```

## 13. systemd 서비스 예시

`/etc/systemd/system/ovpn-issuer.service`

```ini
[Unit]
Description=OpenVPN Bootstrap Issuer API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/ovpn-issuer
EnvironmentFile=-/etc/ovpn-issuer/issuer.env
ExecStart=/opt/ovpn-issuer/venv/bin/uvicorn app:APP --host 0.0.0.0 --port 8443 --ssl-certfile /etc/nginx/tls/bootstrap.crt --ssl-keyfile /etc/nginx/tls/bootstrap.key
Restart=always
RestartSec=3
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

기동:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now ovpn-issuer
sudo systemctl status ovpn-issuer --no-pager
```

메모:

- 현재 실습 서버에서는 `172.16.200.44` private IP 직결이 가장 단순하다.
- 이유:
  - `/etc/nginx/tls/bootstrap.crt`에 `IP:172.16.200.44` SAN이 이미 들어 있다.
  - `issuer.internal`은 아직 Private DNS와 DNS SAN이 준비되지 않았다.
- 이 구성을 실제 worker node가 쓰려면 `ta-sgh-ca` 보안그룹에서 `TCP/8443` inbound를 해당 nodegroup source 대역 기준으로 허용해야 한다.

## 14. API 동작 검증 예시

현재 서버에서 실제 성공한 self-test 예시는 아래와 같다.

```bash
cat >/tmp/issuer-auto-selftest-node-01.json <<'EOF'
{
  "node_id": "issuer-auto-selftest-node-01",
  "node_group": "default-worker",
  "role": "worker",
  "cluster": "ta-sgh-pri-cls",
  "metadata": {
    "instance_id": "instance-auto-selftest-001",
    "local_hostname": "issuer-auto-selftest-node-01",
    "private_ip": "172.16.200.44"
  }
}
EOF

curl -fsS --cacert /srv/bootstrap/ovpn/packages/bootstrap-root-ca.pem \
  -u "bootstrap:<BOOTSTRAP_PASSWORD>" \
  -X POST https://172.16.200.44:8443/v1/bootstrap/node-token \
  -H "Content-Type: application/json" \
  --data @/tmp/issuer-auto-selftest-node-01.json \
  -o /tmp/issuer-node-token-response.json

NODE_TOKEN="$(python3 - <<'PY' /tmp/issuer-node-token-response.json
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["token"])
PY
)"

curl -fsS --cacert /srv/bootstrap/ovpn/packages/bootstrap-root-ca.pem \
  -X POST https://172.16.200.44:8443/v1/bootstrap/node-bundle \
  -H "Authorization: Bearer ${NODE_TOKEN}" \
  -H "Content-Type: application/json" \
  --data @/tmp/issuer-auto-selftest-node-01.json \
  -o /tmp/issuer-auto-selftest-node-01.tar.gz
```

성공 기준:

- `GET /healthz` -> `{"ok":true}`
- `node-token` 응답 JSON에 `token`, `expires_at`, `subject`, `node_group`, `cluster` 포함
- 응답 tarball 안에 `ca.crt`, `client.crt`, `client.key`, `tls-crypt.key`, `bundle-info.txt`
- 같은 token으로 2번째 호출 시 `409 token already used`

신규 node 자동 발급 self-test도 현재 서버에서 아래 조건으로 실제 성공했다.

- 1단계: `Basic Auth -> /v1/bootstrap/node-token`
- 2단계: 발급된 `auto-node-...` token으로 `/v1/bootstrap/node-bundle`
- `EASYRSA_PASSIN=file:/opt/ovpn-issuer/ca-key-passphrase`
- `ca-key-passphrase` 파일 내용: `build-ca` 때 사용한 값
- self-test 요청값:
  - `node_id=issuer-auto-selftest-node-01`
  - `node_group=default-worker`
  - `cluster=ta-sgh-pri-cls`
  - `metadata.instance_id=instance-auto-selftest-001`
  - `metadata.local_hostname=issuer-auto-selftest-node-01`
  - `metadata.private_ip=172.16.200.44`
- 결과:
  - `HTTP 200`
  - 응답 tarball 안에 `ca.crt`, `client.crt`, `client.key`, `tls-crypt.key`, `bundle-info.txt`
  - `tokens.json`에 runtime token이 `issued_at`, `issued_by`, `used_at`, `used_by`와 함께 기록
  - token은 성공 후 `used=true`로 소모

## 15. 자동 발급 구현 완료 범위와 확장 범위

현재 서버 기준으로는 아래까지 완료됐다.

- private IP `172.16.200.44:8443`에서 `Issuer API` 기동
- `worker node`용 `Basic Auth -> node-token -> node-bundle` 2단계 자동 발급
- 완전히 새로운 `node_id`에 대한 신규 cert 서명과 bundle 응답
- token 재사용 차단

아직 별도 구현이 필요한 것:

- 새 worker node 1대에 대한 end-to-end 자동발급 접속 검증
- `gateway-token`, `gateway-bundle` endpoint 확장
- `workload-token`, `workload-bundle` endpoint 확장
- 발급 감사 로그 적재
- revoke API와 CRL publish API의 실제 구현
- 고가용성
