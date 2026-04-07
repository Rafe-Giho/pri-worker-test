# OpenVPN 자동 발급형 Issuer API 가이드

이 문서는 `정적 bootstrap endpoint`와 `OpenVPN 연결 검증`이 끝난 뒤, `자동 발급형 Issuer API`를 별도로 구현할 때 본다.

권장 순서:

1. `openvpn-nks-implementation-appendix.md`의 `5.1 ~ 5.11` 완료
2. `6장 OpenVPN 서버`, `7장 worker node 방식` 또는 `8장 Gateway VM 방식`으로 실제 VPN 연결 검증
3. 그 다음에만 이 문서를 따라 `Issuer API`를 붙인다

## 1. 자동 발급형 Issuer API 설계안

운영형으로 가면 `정적 bundle 저장소`만으로는 부족할 수 있다. 이때는 `고정된 Issuer API endpoint`가 `신원 검증 -> cert 발급 -> bundle packaging -> 응답`까지 수행하게 만든다.

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
- 발급 요청자는 반드시 식별 가능해야 함
- 발급/폐기 로그는 감사 가능한 형태로 남겨야 함
- `duplicate-cn`은 허용하지 않음

## 2. Issuer API endpoint 예시

| Endpoint | 호출 주체 | 용도 | 기본 응답 |
|---|---|---|---|
| `POST /v1/bootstrap/node-bundle` | `worker user script` | node별 cert/bundle 발급 | `tar.gz` 또는 `download_url` |
| `POST /v1/bootstrap/gateway-bundle` | `cloud-init`, `ansible`, 운영자 | gateway VM cert/bundle 발급 | `tar.gz` 또는 `download_url` |
| `POST /v1/bootstrap/workload-bundle` | CI, controller, 운영자 | workload 단위 sidecar bundle 발급 | `JSON + secret payload` 또는 `download_url` |
| `POST /v1/certs/revoke` | 운영자, 자동화 파이프라인 | cert 폐기 | `revoked=true` |
| `POST /v1/crl/publish` | 운영 파이프라인 | 새 `crl.pem` 배포 | `published=true` |

권장:

- `node/gateway`는 `bundle tar.gz` 직접 응답 또는 짧은 만료 `download_url`
- `sidecar`는 `JSON metadata + Secret 생성용 파일 세트` 반환이 다루기 쉽다

## 3. 요청/응답 예시

Node bundle 요청:

```http
POST /v1/bootstrap/node-bundle
Authorization: Bearer <BOOTSTRAP_TOKEN>
Content-Type: application/json

{
  "node_id": "ng-a-worker-20260403-01",
  "node_group": "nodegroup-a",
  "role": "worker",
  "cluster": "nks-pri-test"
}
```

응답 예시 1. 직접 bundle 반환:

```http
200 OK
Content-Type: application/gzip
Content-Disposition: attachment; filename="ng-a-worker-20260403-01.tar.gz"
```

응답 예시 2. URL 반환:

```json
{
  "cn": "ovpn-node-ng-a-worker-20260403-01",
  "download_url": "https://<BOOTSTRAP_ENDPOINT_PRIVATE_IP>/ovpn/issued/ng-a-worker-20260403-01.tar.gz?sig=...",
  "expires_at": "2026-04-03T10:05:00Z"
}
```

Workload bundle 요청:

```http
POST /v1/bootstrap/workload-bundle
Authorization: Bearer <ISSUER_API_TOKEN>
Content-Type: application/json

{
  "namespace": "app-ns",
  "workload": "app1",
  "type": "deployment",
  "bundle_scope": "workload"
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

- `PoC`: 사전 주입된 짧은 만료 bootstrap token
- `운영 권장`: 다음 중 하나
  - 인스턴스 메타데이터 기반 1회성 토큰
  - bootstrap용 mTLS cert
  - 사설망 IP + 추가 토큰의 2중 검증

Sidecar / Workload:

- `CI/CD`가 Issuer API를 호출
- 또는 `cluster 내부 controller`가 `ServiceAccount`로 호출
- Pod가 직접 발급 API를 두드리게 하기보다는 `controller/CI` 경유가 더 안전하다

PoC용 token 생성 예시:

```bash
NODE_TOKEN="$(openssl rand -hex 24)"
GATEWAY_TOKEN="$(openssl rand -hex 24)"
WORKLOAD_TOKEN="$(openssl rand -hex 24)"

jq \
  --arg nt "$NODE_TOKEN" \
  --arg gt "$GATEWAY_TOKEN" \
  --arg wt "$WORKLOAD_TOKEN" \
  '.tokens = {
    ($nt): {"scope":"node","subject":"ng-a-worker-20260403-01"},
    ($gt): {"scope":"gateway","subject":"gw-pri-01"},
    ($wt): {"scope":"workload","subject":"app-ns/app1"}
  }' \
  /opt/ovpn-issuer/tokens.json | sudo tee /opt/ovpn-issuer/tokens.json >/dev/null
```

cluster 내부 controller 또는 운영 검증용 ServiceAccount token 예시:

```bash
kubectl -n app-ns create serviceaccount ovpn-issuer-caller
kubectl -n app-ns create token ovpn-issuer-caller
```

실무 메모:

- `PoC`: 정적 token 파일로 충분하다.
- `운영`: token 1회성 소모, 만료시각, 발급 이력, 호출자 IP 또는 mTLS를 같이 묶는 편이 맞다.

## 5. 방안별 자동 발급 적용 방법

주 방안 / `User Script`:

```text
node boot
  -> user script
  -> POST /v1/bootstrap/node-bundle
  -> node별 bundle 수신
  -> /etc/openvpn/client/pki 배치
  -> openvpn-client@worker-egress 시작
```

주 방안 / `직접 설치`:

```text
운영자
  -> POST /v1/bootstrap/node-bundle 또는 로컬 발급 스크립트 실행
  -> 번들 수신
  -> 대상 node에 배포
  -> OpenVPN client 시작
```

주 방안 / `DaemonSet`:

```text
DaemonSet Pod
  -> host namespace 진입
  -> POST /v1/bootstrap/node-bundle
  -> host /etc/openvpn/client/pki 배치
  -> host OpenVPN service 재기동
```

추가 방안 1 / `Gateway VM`:

```text
gateway VM boot
  -> cloud-init 또는 ansible
  -> POST /v1/bootstrap/gateway-bundle
  -> gateway별 bundle 수신
  -> OpenVPN client 시작
```

추가 방안 2 / `Sidecar`:

```text
CI 또는 controller
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
- `배포 저장소`
  - `/srv/bootstrap/ovpn/issued/<ID>.tar.gz` 같은 고정 저장소 또는 직접 응답 방식
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
  -> /srv/bootstrap/ovpn/issued/<NODE_ID>.tar.gz 저장 또는 직접 응답
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
  | - /srv/bootstrap/ovpn/issued 저장             |
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
  issued/
  revoked/
```

## 10. Issuer API 역할 패키지 설치

```bash
## 외부 다운로드 호스트 - apt 패키지
sudo apt-get update
sudo apt-get install -y apt-rdepends

mkdir -p pkg/issuer-host/debs
cd pkg/issuer-host/debs

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

## CA / Bootstrap Server
sudo install -d -m 0750 /root/pkg/issuer-host/debs
sudo install -d -m 0750 /root/pkg/issuer-host/wheels
sudo tar xzf issuer-host-debs.tar.gz -C /root/pkg/issuer-host/debs
sudo tar xzf issuer-host-wheels.tar.gz -C /root/pkg/issuer-host/wheels

sudo bash -lc 'dpkg -i /root/pkg/issuer-host/debs/*.deb || true'
sudo bash -lc 'DEBIAN_FRONTEND=noninteractive apt-get -o Dir::Cache::archives=/root/pkg/issuer-host/debs --no-download -f install -y'

sudo install -d -m 0750 /opt/ovpn-issuer
sudo install -d -m 0750 /opt/ovpn-issuer/logs
sudo install -d -m 0750 /srv/bootstrap/ovpn/issued
sudo install -d -m 0750 /srv/bootstrap/ovpn/revoked

python3 -m venv /opt/ovpn-issuer/venv
/opt/ovpn-issuer/venv/bin/pip install --no-index --find-links=/root/pkg/issuer-host/wheels fastapi uvicorn
```

메모:

- `Issuer API 역할`도 private 구간이면 인터넷 outbound가 없으므로 `pip install fastapi uvicorn`을 직접 치지 않는다.
- wheel 파일까지 외부에서 미리 받아와 `--no-index`로 설치해야 문서 전제가 맞다.
- 외부 다운로드 호스트에서 `python3 -m pip download`를 쓰려면 해당 호스트에는 최소 `python3-pip`가 준비돼 있어야 한다.

## 11. PoC용 bootstrap token 저장 형식

PoC에서는 아래처럼 정적 token manifest를 둘 수 있다.

`/opt/ovpn-issuer/tokens.json`

```json
{
  "tokens": {
    "node-bootstrap-token-001": {
      "scope": "node",
      "subject": "ng-a-worker-20260403-01"
    },
    "gateway-bootstrap-token-001": {
      "scope": "gateway",
      "subject": "gw-pri-01"
    },
    "workload-issuer-token-001": {
      "scope": "workload",
      "subject": "app-ns/app1"
    }
  }
}
```

운영에서는 이 정적 파일 대신 아래 중 하나로 바꾼다.

- metadata 기반 1회성 token
- bootstrap mTLS
- 별도 token 저장소 또는 DB

## 12. Issuer API 서버 예시 코드

아래 예시는 `node`, `gateway`, `workload` 발급을 모두 수행하는 최소 PoC 구현이다.

`/opt/ovpn-issuer/app.py`

```python
import base64
import json
import shutil
import subprocess
from pathlib import Path

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel


APP = FastAPI()

TOKENS_FILE = Path("/opt/ovpn-issuer/tokens.json")
EASYRSA_HOME = Path("/opt/easy-rsa")
ISSUE_SCRIPT = EASYRSA_HOME / "scripts" / "issue-client-bundle.sh"
BOOTSTRAP_DIR = Path("/srv/bootstrap/ovpn/issued")


class NodeBundleRequest(BaseModel):
    node_id: str
    node_group: str
    role: str
    cluster: str


class GatewayBundleRequest(BaseModel):
    gateway_id: str
    role: str = "gateway"


class WorkloadBundleRequest(BaseModel):
    namespace: str
    workload: str
    type: str
    bundle_scope: str = "workload"


def load_tokens() -> dict:
    with TOKENS_FILE.open("r", encoding="utf-8") as fp:
        return json.load(fp)["tokens"]


def verify_token(authorization: str | None, expected_scope: str, expected_subject: str) -> None:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.split(" ", 1)[1]
    tokens = load_tokens()
    entry = tokens.get(token)
    if not entry:
        raise HTTPException(status_code=403, detail="invalid token")
    if entry["scope"] != expected_scope:
        raise HTTPException(status_code=403, detail="scope mismatch")
    if entry["subject"] != expected_subject:
        raise HTTPException(status_code=403, detail="subject mismatch")


def run_issue(cn: str, bundle_type: str) -> Path:
    subprocess.run(
        [str(ISSUE_SCRIPT), cn, bundle_type],
        cwd=str(EASYRSA_HOME),
        check=True,
    )
    if bundle_type == "node":
        bundle_dir = EASYRSA_HOME / "dist" / "nodes" / cn
    elif bundle_type == "gateway":
        bundle_dir = EASYRSA_HOME / "dist" / "gateways" / cn
    else:
        bundle_dir = EASYRSA_HOME / "dist" / "pods" / cn
    return bundle_dir


@APP.get("/healthz")
def healthz():
    return {"ok": True}


@APP.post("/v1/bootstrap/node-bundle")
def node_bundle(req: NodeBundleRequest, authorization: str | None = Header(default=None)):
    verify_token(authorization, "node", req.node_id)
    cn = f"ovpn-node-{req.node_id}"
    bundle_dir = run_issue(cn, "node")
    src = bundle_dir.parent / f"{cn}.tar.gz"
    dst = BOOTSTRAP_DIR / f"{req.node_id}.tar.gz"
    shutil.copy2(src, dst)
    return FileResponse(path=dst, filename=f"{req.node_id}.tar.gz", media_type="application/gzip")


@APP.post("/v1/bootstrap/gateway-bundle")
def gateway_bundle(req: GatewayBundleRequest, authorization: str | None = Header(default=None)):
    verify_token(authorization, "gateway", req.gateway_id)
    cn = f"ovpn-gw-{req.gateway_id}"
    bundle_dir = run_issue(cn, "gateway")
    src = bundle_dir.parent / f"{cn}.tar.gz"
    dst = BOOTSTRAP_DIR / f"{req.gateway_id}.tar.gz"
    shutil.copy2(src, dst)
    return FileResponse(path=dst, filename=f"{req.gateway_id}.tar.gz", media_type="application/gzip")


@APP.post("/v1/bootstrap/workload-bundle")
def workload_bundle(req: WorkloadBundleRequest, authorization: str | None = Header(default=None)):
    subject = f"{req.namespace}/{req.workload}"
    verify_token(authorization, "workload", subject)
    cn = f"ovpn-pod-{req.namespace}-{req.workload}"
    bundle_dir = run_issue(cn, "pod")
    payload = {}
    for name in ("ca.crt", "client.crt", "client.key", "tls-crypt.key"):
        payload[name] = base64.b64encode((bundle_dir / name).read_bytes()).decode("ascii")
    return JSONResponse({"cn": cn, "files": payload})
```

이 예시의 의도:

- `node/gateway`는 `tar.gz` 직접 반환
- `workload`는 Kubernetes Secret 생성이 쉬운 `base64 JSON` 반환
- token 검증은 단순화
- 같은 token의 재사용 차단은 PoC에서 생략

실무 메모:

- 같은 token 재사용 차단이 필요하면 DB 또는 1회성 token 저장소를 둔다
- 발급 이벤트는 별도 파일 또는 syslog로 남긴다
- 운영에서는 `Issuer API 역할`도 `CA / Bootstrap Server` 안에서 `Private VPC`로만 노출한다

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
ExecStart=/opt/ovpn-issuer/venv/bin/uvicorn app:APP --host 0.0.0.0 --port 8443 --ssl-certfile /etc/ovpn-issuer/tls/issuer.crt --ssl-keyfile /etc/ovpn-issuer/tls/issuer.key
Restart=always
RestartSec=3

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

- `issuer.internal` FQDN을 쓰는 편이 가장 단순하다.
- private IP로 직접 붙는다면 서버 인증서에 해당 IP SAN이 들어 있어야 한다.

## 14. API 동작 검증 예시

Node bundle 요청:

```bash
curl -fsS --cacert /etc/ssl/certs/issuer-root-ca.pem -X POST https://issuer.internal:8443/v1/bootstrap/node-bundle \
  -H "Authorization: Bearer node-bootstrap-token-001" \
  -H "Content-Type: application/json" \
  --data '{"node_id":"ng-a-worker-20260403-01","node_group":"nodegroup-a","role":"worker","cluster":"nks-pri-test"}' \
  -o /tmp/ng-a-worker-20260403-01.tar.gz
```

Gateway bundle 요청:

```bash
curl -fsS --cacert /etc/ssl/certs/issuer-root-ca.pem -X POST https://issuer.internal:8443/v1/bootstrap/gateway-bundle \
  -H "Authorization: Bearer gateway-bootstrap-token-001" \
  -H "Content-Type: application/json" \
  --data '{"gateway_id":"gw-pri-01"}' \
  -o /tmp/gw-pri-01.tar.gz
```

Workload bundle 요청:

```bash
curl -fsS --cacert /etc/ssl/certs/issuer-root-ca.pem -X POST https://issuer.internal:8443/v1/bootstrap/workload-bundle \
  -H "Authorization: Bearer workload-issuer-token-001" \
  -H "Content-Type: application/json" \
  --data '{"namespace":"app-ns","workload":"app1","type":"deployment","bundle_scope":"workload"}'
```

## 15. 자동 발급 구현 경계

이 섹션까지 적용하면 `PoC 수준의 자동 발급 API 서버`는 구현 가능하다.

즉시 가능한 것:

- node별 자동 발급
- gateway별 자동 발급
- workload별 Secret 생성용 bundle 응답

아직 별도 구현이 필요한 것:

- token 1회성 소모
- metadata 기반 bootstrap token 발급
- 발급 감사 로그 적재
- revoke API와 CRL publish API의 실제 구현
- 고가용성
