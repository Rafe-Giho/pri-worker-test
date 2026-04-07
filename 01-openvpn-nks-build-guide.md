# 01. NKS Private Worker Outbound OpenVPN 구축 가이드

## 1. 문서 목적과 범위

이 문서는 `NHN Cloud Private NKS` 환경에서 `Private Worker Node`의 외부 outbound를 `OpenVPN`으로 우회시키는 현재 표준 구성을 설명한다.

표기 원칙:

- `템플릿`: `<PLACEHOLDER>` 형식 또는 일반화된 이름을 사용한다
- `실환경 예시`: 현재 검증 완료한 값과 이름을 그대로 적는다
- 운영 문서는 가능하면 `템플릿 -> 실환경 예시` 순서로 본다

현재 기준으로 이 문서가 다루는 범위는 아래와 같다.

- 구현 완료 및 검증 완료
  - `Public VPC OpenVPN Server`
  - `Private VPC CA / Bootstrap / Issuer API`
  - `NodeGroup-A / worker-egress user script`
  - `Basic Auth -> node-token -> node-bundle` 기반 full-auto 인증서 발급
  - `split DNS`
  - 새 worker node scale-out 시 자동 발급 후 VPN 연결
- 확장 설계만 정리된 범위
  - `Gateway VM` full-auto 발급
  - `Pod sidecar` full-auto 발급

즉, 현재 실무 표준은 `Worker Node 직접 OpenVPN client + full-auto Issuer API`다.

## 2. 현재 표준 구성

### 2.1 기술 스택

- `NKS Private Zone`
- `Ubuntu 22.04 LTS`
- `OpenVPN OSS 2.6.x`
- `Easy-RSA 3.2.x`
- `FastAPI + Uvicorn`
- `systemd-resolved`
- `NHN Cloud Private DNS`
- `NCR / OBS Service Gateway`
- `cloud-init / NKS user script`

### 2.2 구성 요소

- `OpenVPN Server`
  - 위치: `Public VPC`
  - 역할: VPN 종단, 복호화, SNAT, 인터넷 출구
- `CA / Bootstrap / Issuer API`
  - 위치: `Private VPC`
  - 역할: CA 키 관리, bootstrap 스크립트 배포, worker cert 자동 발급
- `NKS Private Cluster`
  - `NodeGroup-A`
    - 역할: 주 방안. worker node에 OpenVPN client 설치, 외부 outbound를 VPN 경유
  - `NodeGroup-B`
    - 역할: 추가 방안 1 검증용. worker node는 일반 경로를 유지하고 subnet/route를 `Gateway VM`으로 우회
  - `NodeGroup-C`
    - 역할: 추가 방안 2 검증용. sidecar를 붙이는 workload를 분리 배치
- `VPN Gateway VM`
  - 위치: `Private VPC`
  - 역할: `NodeGroup-B`의 외부 outbound next hop
- `Private DNS`
  - 역할: `NCR/OBS/VPC internal name`은 `eth0` 쪽 resolver로 해석
- `Public DNS`
  - 역할: `google.com` 같은 public name은 `tun0` 쪽 resolver로 해석

### 2.3 현재 구현 완료 범위

- `Issuer API`는 `172.16.200.44:8443`에서 동작
- worker node는 아래 2단계로 bundle을 받는다.
  1. `POST /v1/bootstrap/node-token`
  2. `POST /v1/bootstrap/node-bundle`
- bootstrap credential은 `Basic Auth`
- 실제 VPN 접속은 발급된 `client.crt`, `client.key`, `tls-crypt.key`로 수행
- node 재부팅 시에는 기존 발급 파일로 재연결하고, bootstrap token은 다시 필요하지 않다

## 3. 권장 아키텍처

이 문서의 아키텍처는 `공통 베이스`와 `방안별 세부 아키텍처`를 나눠서 보는 편이 맞다.

- 공통 베이스:
  - `Public VPC OpenVPN Server`
  - `Private VPC CA / Bootstrap / Issuer API`
  - `Private DNS`, `NCR / OBS SGW`
  - `Private NKS Cluster`
- 방안별 세부 아키텍처:
  - `주 방안`: `NodeGroup-A / worker 직접 OpenVPN client`
  - `추가 방안 1`: `NodeGroup-B / Gateway VM`
  - `추가 방안 2`: `NodeGroup-C / Pod sidecar`

### 3.1 공통 베이스 아키텍처

```text
[Internet / External APIs]
              ^
              |
      +----------------------+
      | OpenVPN Server VM    |
      | Public VPC           |
      | - VPN 종단           |
      | - 복호화 / SNAT      |
      +----------------------+
                 ^
                 | OpenVPN tunnel
                 |
  +----------------------------------------------------------+
  | Private VPC                                              |
  |                                                          |
  |  +-----------------------------------------------+       |
  |  | CA / Bootstrap / Issuer API                   |       |
  |  | - Easy-RSA                                    |       |
  |  | - bootstrap script repo                       |       |
  |  | - /v1/bootstrap/node-token                    |       |
  |  | - /v1/bootstrap/node-bundle                   |       |
  |  +-----------------------------------------------+       |
  |                                                          |
  |  +-----------------------------------------------+       |
  |  | NKS Private Cluster                            |       |
  |  | - NodeGroup-A (worker 직접 OpenVPN client)     |       |
  |  | - NodeGroup-B (Gateway VM 경유)                |       |
  |  | - NodeGroup-C (Pod sidecar)                    |       |
  |  +-----------------------------------------------+       |
  |                                                          |
  |  +----------------------+                                |
  |  | VPN Gateway VM       |                                |
  |  +----------------------+                                |
  |                                                          |
  |  +----------------------+   +----------------------+      |
  |  | Private DNS          |   | NCR / OBS SGW        |      |
  |  +----------------------+   +----------------------+      |
  +----------------------------------------------------------+
```

### 3.2 주 방안 아키텍처 - NodeGroup-A

```text
NodeGroup-A Pod / node process
  -> worker node의 openvpn-client@worker-egress
  -> tun0
  -> Public VPC OpenVPN Server
  -> Internet

단, NCR / OBS / VPC internal name 조회와 SGW 접근은
  -> eth0 + Private DNS
```

- 현재 구현 완료 및 검증 완료 표준이다.
- `user script + Issuer API`로 autoscale 대응이 가장 자연스럽다.
- `split DNS`를 같이 적용해 `Private URI image pull`과 public outbound를 한 node에서 같이 처리한다.

### 3.3 추가 방안 1 아키텍처 - NodeGroup-B + Gateway VM

```text
NodeGroup-B Pod / node process
  -> worker node 기본 라우팅
  -> Private VPC route / next hop = Gateway VM
  -> Gateway VM의 OpenVPN client
  -> Public VPC OpenVPN Server
  -> Internet
```

- worker node 자체에는 OpenVPN client를 넣지 않는 방향이다.
- route, next hop, gateway 이중화가 같이 설계되어야 하므로 worker 직접 설치보다 운영 요소가 더 많다.
- full-auto 발급은 같은 `token -> bundle` 패턴으로 확장할 수 있지만, 현재 실구현은 아니다.

### 3.4 추가 방안 2 아키텍처 - NodeGroup-C + Pod sidecar

```text
NodeGroup-C Pod
  -> app container
  -> 같은 Pod의 OpenVPN sidecar
  -> Public VPC OpenVPN Server
  -> Internet
```

- node 전체가 아니라 특정 workload만 VPN egress를 태우려는 경우의 선택지다.
- `NET_ADMIN`, `/dev/net/tun`, Secret 배포, rollout 재시작 등 운영 복잡도가 가장 높다.
- full-auto 발급은 같은 `token -> bundle` 패턴으로 확장할 수 있지만, 현재 실구현은 아니다.

### 3.5 왜 현재는 NodeGroup-A를 표준으로 삼는가

- OpenVPN 서버를 `Public VPC`에 두면 인터넷 출구 역할이 분명하다
- CA와 Issuer를 `Private VPC`에 두면 CA 키와 bootstrap 자산을 분리할 수 있다
- worker node가 scale-out돼도 `user script + Issuer API`로 자동 발급이 가능하다
- `Private DNS + split DNS`를 같이 쓰면 `NCR/OBS`와 public outbound를 동시에 안정적으로 처리할 수 있다
- 같은 공통 베이스 위에서 `Gateway VM`, `sidecar`까지 확장 가능하지만, 현재까지 end-to-end 검증이 완료된 것은 `NodeGroup-A`다

## 4. VPN 원리와 라우팅 / DNS

### 4.1 VPN 원리

- OpenVPN client는 `tun0`를 만든다
- 외부로 보낼 패킷은 `tun0`로 보내고, OpenVPN이 이를 암호화된 outer packet으로 감싼다
- OpenVPN 서버는 이를 복호화한 뒤 인터넷으로 내보낸다

### 4.2 라우팅 원칙

현재 표준 worker 설정은 `route-nopull` 기반이다.

- `OpenVPN Server IP`는 `eth0 / net_gateway`
- `Private VPC`, `Public VPC`, `Pod CIDR`, `Service CIDR`는 `eth0 / net_gateway`
- 나머지 default outbound는 `tun0 / vpn_gateway`

즉, 클러스터 내부 통신과 VPC 내부 통신은 로컬 경로를 유지하고, 외부 인터넷만 VPN으로 보낸다.

### 4.3 DNS 원칙

현재 표준은 `split DNS`다.

- `eth0 -> Private DNS`
  - `openstacklocal`
  - `container.nhncloud.com`
  - `nhncloudservice.com`
- `tun0 -> 외부 DNS`
  - 그 외 public domain

즉 결과적으로:

- `private-c097...registry.container.nhncloud.com` -> `eth0`
- `kr1-api-object-storage.nhncloudservice.com` -> `eth0`
- `www.google.com` -> `tun0`

추가 원칙:

- `*.svc.cluster.local` 같은 `k8s service` 이름은 Pod 기본값이 `dnsPolicy: ClusterFirst`이면 `CoreDNS`가 클러스터 내부에서 직접 처리한다.
- 즉 현재 `split DNS`는 `private service name`과 `public domain`의 upstream 선택에 영향을 주는 것이지, `cluster.local` 이름 자체를 대체하는 것이 아니다.
- 다만 `Service CIDR`, `Pod CIDR`가 잘못 라우팅되거나 `CoreDNS`가 비정상이면 `cluster.local`도 깨질 수 있으므로, 내부 통신 route는 반드시 `eth0`에 남겨야 한다.
- `Ingress host` 예: `app.example.internal`은 `CoreDNS`가 자동으로 만들어 주는 이름이 아니므로, 별도의 `Private DNS` 또는 공인 DNS 레코드가 필요하다.

## 5. 표준 통신 흐름

이 절에서는 먼저 현재 과제의 목표인 `Pod에서 외부 URL 호출` 흐름을 본다. worker 인증서 자동발급은 이를 가능하게 하는 선행 lifecycle 흐름으로 뒤에서 정리한다.

### 5.1 Pod에서 외부 URL을 호출할 때

1. Pod가 `https://www.google.com` 같은 외부 URL을 호출한다
2. Pod 기본 DNS는 `ClusterFirst`이므로, 우선 `CoreDNS`가 이름을 해석한다
3. `CoreDNS`는 외부 이름을 upstream으로 넘기고, node의 `split DNS` 구성에 따라 public name 해석은 `tun0` 쪽으로 잡힌다
4. Pod의 실제 외부 트래픽은 worker node 라우팅에서 `tun0`를 선택한다
5. OpenVPN tunnel을 통해 `Public VPC OpenVPN Server`로 전송된다
6. OpenVPN Server가 복호화 후 SNAT한다
7. 인터넷으로 outbound를 수행한다

### 5.2 Pod에서 k8s 내부 이름을 호출할 때

1. Pod가 `kubernetes.default.svc.cluster.local` 또는 `<svc>.<ns>.svc.cluster.local`을 조회한다
2. `CoreDNS`가 클러스터 내부에서 직접 응답한다
3. `Service CIDR`, `Pod CIDR`는 `eth0 / net_gateway` 쪽에 남아 있으므로 내부 통신은 VPN으로 빠지지 않는다

즉 `cluster.local` 이름은 현재 `split DNS`가 아니라 `CoreDNS + 내부 route`가 성패를 좌우한다.

### 5.3 Private URI image pull 흐름

1. `kubelet/containerd`가 `private-...registry.container.nhncloud.com` 또는 `kr1-api-object-storage...`를 조회한다
2. node의 `systemd-resolved`가 routed domain 규칙에 따라 `eth0` 쪽 `Private DNS`를 사용한다
3. `Private DNS`가 `Service Gateway` 기준 IP를 돌려준다
4. node는 `eth0` 경로로 `NCR / OBS SGW`에 붙는다
5. 이미지 pull이 성공하면 test Pod가 생성되고, 이후 Pod 외부 호출 검증으로 넘어간다

### 5.4 새 worker node 자동발급 및 VPN 연결

1. 새 worker node가 부팅된다
2. NKS `user script`가 1차 launcher를 실행한다
3. 1차 launcher가 bootstrap 서버에서 2차 스크립트를 내려받는다
4. 2차 스크립트가 bootstrap CA, runtime package, node metadata를 준비한다
5. 2차 스크립트가 `POST /v1/bootstrap/node-token`을 호출한다
6. Issuer API가 bootstrap credential과 metadata를 검증하고 짧은 만료의 1회성 token을 발급한다
7. 2차 스크립트가 `POST /v1/bootstrap/node-bundle`을 호출한다
8. Issuer API가 cert/key/tls-crypt bundle을 생성해 반환한다
9. node는 `/etc/openvpn/client/pki`와 `worker-egress.conf`를 구성한다
10. `openvpn-client@worker-egress`가 기동되고 `tun0`가 올라온다

### 5.5 재부팅과 scale-out 동작

현재 `Issuer API` 구현은 요청-응답형 동기 처리다.

- `같은 node reboot`
  - 기존 cert 파일로 다시 OpenVPN에 붙는다
  - Issuer API는 다시 호출하지 않아도 된다
- `새 node scale-out`
  - 새 metadata로 `node-token -> node-bundle`을 다시 수행한다
  - 새 cert를 자동 발급받는다
- `node-token`은 빠르게 여러 개 발급될 수 있다
- 실제 `node-bundle` 발급은 CA 서버에서 직렬화될 수 있다
- 따라서 여러 node가 동시에 늘어나면 VPN 연결 완료 시점은 순차적으로 밀릴 수 있다

즉 현재 구현은 `정합성 우선`, `burst scale-out 처리량은 제한적`인 구조다.

## 6. 구축 순서

현재 실무 기준 구축 순서는 아래가 맞다.

1. 공통 준비
   - VPC peering
   - 보안그룹
   - `Private DNS`
   - `NCR / OBS SGW`
2. `Private VPC CA / Bootstrap Server` 구축
   - 공통 PKI
   - `bootstrap endpoint packages`
3. `Public VPC OpenVPN Server` 구축
4. `Issuer API` 구축
5. `NodeGroup-A` full-auto user script 적용
6. 새 worker node scale-out 검증
7. 운영 자동화 / 장애 대응 문서 보강
8. 필요 시 `Gateway VM`, `sidecar` 확장

## 7. 문서 순번

현재 파일명은 아래 순번 기준으로 이미 정리돼 있다.

| 순번 | 문서 | 역할 |
|---|---|---|
| `01` | [01-openvpn-nks-build-guide.md](./01-openvpn-nks-build-guide.md) | 전체 구조, 원리, 구축 순서 |
| `02` | [02-openvpn-nks-implementation-appendix.md](./02-openvpn-nks-implementation-appendix.md) | 상세 절차, 스크립트, 설정 템플릿 |
| `03` | [03-openvpn-server-build-guide.md](./03-openvpn-server-build-guide.md) | Public VPC OpenVPN Server 구축 |
| `04` | [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md) | Issuer API 구축과 자동발급 구조 |
| `05` | [05-openvpn-nks-operations-appendix.md](./05-openvpn-nks-operations-appendix.md) | 운영 절차, 갱신, 자동화 |
| `06` | [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md) | 장애 대응, 점검 순서 |
| `07` | [07-openvpn-nks-test-guide.md](./07-openvpn-nks-test-guide.md) | 개인 검증용 테스트 절차 |

## 8. 구현안별 적합도

| 구현안 | 적합도 | 비고 |
|---|---:|---|
| `NodeGroup-A / worker 직접 OpenVPN client` | 높음 | 현재 구현 완료 및 검증 완료 표준. `split DNS`, `Private URI image pull`, `pod curl google.com`까지 확인 |
| `NodeGroup-B / Gateway VM` | 중상 | 네트워크 경계 통제는 좋지만 gateway route, HA, full-auto 발급 확장이 추가로 필요 |
| `NodeGroup-C / Pod sidecar` | 중하 | 선택 적용은 좋지만 Secret/배포 자동화, Pod 권한, 운영 복잡도가 더 높음 |

## 9. 실무 체크포인트

- `Private NKS`에서 `Private NCR`을 쓰려면 `Private DNS + SGW`를 먼저 맞춘다
- `OpenVPN` 라우팅과 `NCR/OBS` name resolution을 같은 문제로 섞어 보면 안 된다
- `Pod CIDR`, `Service CIDR`은 반드시 `eth0`에 남겨야 한다
- `tun0=외부 DNS`, `eth0=Private DNS` 원칙을 깨면 `NCR` 조회가 public DNS로 새기 쉽다
- `Issuer API`는 지금 구조상 burst scale-out 병목이 될 수 있으므로, 필요 시 node image bake나 worker 증설을 검토한다

## 10. 최종 권고

현재 시점의 최종 권고는 아래와 같다.

- 기본 표준
  - `NodeGroup-A / worker 직접 OpenVPN client`
  - `Private DNS + SGW`
  - `Issuer API full-auto`
- 시험/확장 방향
  - `NodeGroup-B`는 `Gateway VM` 방안 검증용
  - `NodeGroup-C`는 `Pod sidecar` 방안 검증용
  - 즉 클러스터 내 node group 분리는 `표준 운영`과 `추가 방안 비교 검증`을 같이 고려한 구조로 본다
- 운영 문서화 기준
  - 원리, 통신 흐름, 구축 절차, 운영 절차, 트러블슈팅을 문서별로 분리
  - 메인 문서는 현재 검증 완료 범위만 표준으로 선언
- 이후 확장
  - `Gateway VM`, `sidecar`는 같은 `token -> bundle` 패턴으로 확장
  - 다만 실제 구현과 검증 전에는 표준 운영 경로로 간주하지 않는다
