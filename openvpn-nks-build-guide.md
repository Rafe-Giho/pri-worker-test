# NKS Private Worker Outbound OpenVPN 구축 가이드

## 1. 과업 개요

### 1.1 목표

- 폐쇄망 `Worker Node`의 Pod에서 `curl google.com` 응답을 받는다.
- 대상 환경은 `NHN testbed`, `NKS Private Zone`이다.
- 외부 인터넷/API 통신은 `OpenVPN`을 반드시 경유하는 방식으로 검토한다.

### 1.2 결과물

- 실환경 검증 완료 후 결과 메일 회신
- 팀두레이에 아래 내용을 정리해 업로드
  - 원리
  - 통신 흐름
  - 구성 방식별 장단점
  - 적용 절차와 운영 포인트

### 1.3 기한

- `2026-04-07 18:00 (KST)`

### 1.4 배경

- Native 전환 사업에서 `인터넷이 직접 되지 않는 구간`의 외부 API 통신을 어떻게 구성할지 탐구하고 숙달하는 목적이다.

### 1.5 이번 문서에서 다루는 방안

- 주 방안: `Public VPC OpenVPN Server(VM) + 각 worker node에 OpenVPN client 설치`
  - 세부 1: `NKS User Script`로 자동 설치
  - 세부 2: node에 직접 설치
  - 세부 3: `DaemonSet` 등 자동 설치
- 추가 방안 1: `Public VPC OpenVPN Server(VM) + Private VPC VPN Gateway VM(Client)`
  - 장점: 네트워크 구간 통제 가능
  - 단점: 단일 장애지점으로 blast radius가 커질 수 있음
- 추가 방안 2: `Pod sidecar`로 OpenVPN client 부착
  - 장점: 외부 통신이 필요한 Pod만 적용 가능
  - 단점: 구조가 복잡하고 보안 예외가 필요함

## 2. 전제와 권장 아키텍처

### 2.1 전제

- OS: `Ubuntu 22.04 LTS` 기준
- OpenVPN: `OpenVPN OSS 2.6.x`
- PKI: `Easy-RSA 3.2.x`
- NKS worker: Linux
- Public VPC와 Private VPC는 `Peering` 연결됨
- OpenVPN 서버는 Public VPC의 `private IP`로 peering 경유 접근하는 것을 권장
  - 서버가 인터넷으로 나가기만 하면 되므로, worker/client가 굳이 서버의 public IP로 붙을 필요는 없음

### 2.2 전체 아키텍처

```text
[Internet / External APIs]
              ^
              |
[Public VPC]
+---------------------------------------------------------------+
| Public subnet                                                 |
|  +-----------------------------------------+                  |
|  | OpenVPN Server VM                       |                  |
|  | - VPN 종단                              |                  |
|  | - 복호화 / SNAT / Internet NAT          |                  |
|  +-----------------------------------------+                  |
|                           |                                   |
|                           v                                   |
|                    Internet Gateway                           |
+---------------------------------------------------------------+

[Private VPC]
+----------------------------------------------------------------------------------+
| Private subnet (Ops / PKI)                                                       |
|  +--------------------+                                                           |
|  | CA Server VM       |                                                           |
|  | - Easy-RSA         |                                                           |
|  | - CA / CRL 관리    |                                                           |
|  | - 번들 패키징      |                                                           |
|  +--------------------+                                                           |
|                                                                                  |
| Private subnet (NKS / Egress)                                                    |
|  +----------------------------------------------+    +----------------------+     |
|  | NKS Cluster (Private Zone)                   |    | VPN Gateway VM       |     |
|  | - NodeGroup-A: worker node에 client         |    | - OpenVPN Client     |     |
|  | - NodeGroup-B: next hop = VPN Gateway VM    |    | - 추가 방안 1        |     |
|  | - NodeGroup-C: Pod + Sidecar client         |    +----------------------+     |
|  +----------------------------------------------+              |                  |
+----------------------------------------------------------------------------------+
        |                                  |                     |
        | bundle / cert / CRL              | OpenVPN tunnel      | OpenVPN tunnel
        +-------------------------------> OpenVPN Server VM <----+
```

### 2.3 왜 CA Server를 Private VPC에 두는가

현재 사용할 VPC가 `Public VPC`와 `Private VPC`뿐이라면, CA 서버는 `Private VPC`에 두는 쪽이 맞다.

중요한 점은 `CA Server VM은 NKS Cluster 안에 두지 않는다`는 것이다.

- CA 서버는 데이터 플레인 장비가 아니라 `인증서 발급/폐기/CRL 관리`용 관리 장비다.
- 인터넷과 직접 맞닿을 이유가 없으므로 `Public VPC`에 둘 이유가 약하다.
- OpenVPN 서버가 침해되더라도 `CA private key`까지 같이 탈취되는 위험을 줄이려면 분리가 필요하다.
- worker, gateway VM, sidecar용 클라이언트 번들을 내부 경로로 배포하기 쉽다.
- 운영 접근 경로는 `사내 관리망 또는 승인된 운영 대역 -> Private VPC CA Server`로 제한하는 편이 안전하다.

즉 이 문서에서는 `Public VPC = VPN 종단 / 인터넷 출구`, `Private VPC = NKS + CA + VPN Gateway + 내부 클라이언트 자산 관리`로 역할을 나눈다.

실무적으로 더 좋은 구조는 `별도 관리 VPC` 또는 `오프라인 CA`지만, 현재 전제에서는 `Private VPC 배치`가 가장 현실적이다.

### 2.4 구현안별 데이터 경로

```text
안 1. 주 방안 / NodeGroup-A / 각 worker node에 OpenVPN client

  Pod
   |
  Worker Node A(Client)
   |
  OpenVPN tunnel
   |
  OpenVPN Server(Public VPC)
   |
  Internet / External APIs

안 2. 추가 방안 1 / NodeGroup-B / Private VPC VPN Gateway VM(Client)

  Pod
   |
  Worker Node B
   |
  node egress next hop = VPN Gateway VM
   |
  Private VPC VPN Gateway VM(Client)
   |
  OpenVPN tunnel
   |
  OpenVPN Server(Public VPC)
   |
  Internet / External APIs

안 3. 추가 방안 2 / NodeGroup-C / Pod sidecar OpenVPN client

  Pod(App + VPN Sidecar Client)
   |
  OpenVPN tunnel
   |
  OpenVPN Server(Public VPC)
   |
  Internet / External APIs
```

### 2.5 원리와 통신 흐름 관점

결과물에는 아래 원리와 흐름을 포함해 설명하는 것을 전제로 한다.

- `VPN`: 원본 패킷을 별도의 터널 인터페이스(`tun0`)로 보내고, 외부로 나갈 때 암호화된 outer packet으로 캡슐화한다.
- `Peering`: Private VPC의 worker/gateway/Pod가 Public VPC의 OpenVPN 서버 `private IP`에 도달할 수 있게 한다.
- `Routing`: 어느 패킷이 `eth0`로 나가고 어느 패킷이 `tun0`로 나갈지 결정한다.
- `DNS`: `curl google.com`은 먼저 DNS 질의를 발생시키므로, Pod의 `/etc/resolv.conf`, CoreDNS, node-local DNS cache, VPC DNS 중 무엇을 쓰는지 반드시 검증해야 한다.
- `Encryption`: OpenVPN server와 client 사이의 outer packet은 암호화되지만, 서버에서 복호화된 뒤 인터넷으로 나갈 때는 일반 IP 패킷이 된다.

공통 통신 흐름은 아래처럼 이해하면 된다.

```text
Pod process
  -> Pod network namespace
  -> CNI datapath
  -> DNS lookup
     -> 보통 CoreDNS 또는 node-local DNS cache
     -> upstream DNS가 어디로 나가는지 별도 검증 필요
  -> worker 또는 gateway 또는 sidecar의 routing table 조회
  -> eth0 또는 tun0 결정
  -> OpenVPN tunnel로 보내는 경우 원본 패킷을 암호화해 outer packet 생성
  -> Public VPC OpenVPN Server
  -> 복호화
  -> SNAT / MASQUERADE
  -> Internet Gateway
  -> 외부 DNS 또는 외부 서비스
```

구현안별로 `tun0`가 생기는 위치만 달라진다.

- `NodeGroup-A / 주 방안`: `Worker Node`에 `tun0`가 생긴다.
- `NodeGroup-B / 추가 방안 1`: `VPN Gateway VM`에 `tun0`가 생기고, 해당 node group의 외부 egress next hop은 `VPN Gateway VM`이 된다.
- `NodeGroup-C / 추가 방안 2`: `Pod network namespace` 안에 `tun0`가 생긴다.

### 2.6 설계 원칙

- `OpenVPN server`는 `인터넷 NAT 출구` 역할까지 수행한다.
- `CA 서버`는 OpenVPN 서버와 분리한다.
- `leaf cert`는 엔티티별로 분리한다.
  - 게이트웨이 VM 1장
  - worker node 1장
  - sidecar는 기본 `workload / deployment` 단위 1장
  - 더 강한 격리가 필요할 때만 `pod` 단위 1장
- `CRL`을 반드시 운영한다.
- `tls-crypt`를 기본 사용한다.
  - 대규모 또는 고위험 환경이면 `tls-crypt-v2` 검토
- `NKS`가 제공하는 기본 컴포넌트와 경로는 먼저 유지한다.
  - 예: `CoreDNS`, 기본 `dnsPolicy`, 기본 cluster DNS 경로
  - 기본값으로 목표가 깨지는 것이 확인됐을 때만 조정한다
- `주 방안`, `추가 방안 2`는 `redirect-gateway`를 서버에서 일괄 push하지 말고, `client config`에서 직접 라우팅을 제어한다.
  - NKS 내부 대역, Service CIDR, VPC CIDR이 VPN으로 빨려 들어가면 장애 난다.

## 3. 구현안별 적합도

| 구현안 | 적합도 | 핵심 판단 |
|---|---:|---|
| 주 방안. 각 worker node에 OpenVPN client | 높음 | 이번 과업 의도와 가장 직접적으로 맞는다. autoscale 대응은 `User Script`가 가장 현실적이다. |
| 추가 방안 1. Private VPC VPN Gateway VM(Client) | 중상 | 네트워크 경계 통제가 쉽다. 대신 gateway 장애 시 영향 범위가 넓다. |
| 추가 방안 2. Pod sidecar OpenVPN client | 중하 | 특정 Pod만 선택적으로 보낼 수 있다. 대신 구조와 운영이 가장 복잡하다. |

## 4. 구현 부록 안내

- 상세 구현 절차, 명령어, 스크립트, 설정 예시는 [openvpn-nks-implementation-appendix.md](./openvpn-nks-implementation-appendix.md)에 분리했다.
- 이 부록에는 기존 가이드의 `## 4. 공통 준비`부터 `## 9. 추가 방안 2 - Pod sidecar OpenVPN client`까지를 원문 그대로 옮겼다.
- 명령어, 스크립트, 설정 예시는 요약하지 않고 그대로 유지했다.

권장 읽기 / 구축 순서:

1. 이 문서의 `2. 전제와 권장 아키텍처`, `3. 구현안별 적합도`를 먼저 읽는다.
2. [openvpn-nks-implementation-appendix.md](./openvpn-nks-implementation-appendix.md)의 `4. 공통 준비`, `5. 공통 PKI / CA 서버 구축`을 수행한다.
3. [openvpn-server-build-guide.md](./openvpn-server-build-guide.md)를 기준으로 `Public VPC OpenVPN Server`를 먼저 완성한다.
4. 다시 [openvpn-nks-implementation-appendix.md](./openvpn-nks-implementation-appendix.md)로 돌아와 `6. 공통 OpenVPN 서버 구축`을 서버 가이드와 대조 확인한다.
5. 그다음 `7. 주 방안`, `8. 추가 방안 1`, `9. 추가 방안 2` 중 검증 대상을 하나씩 수행한다.
6. 마지막에 [openvpn-nks-operations-appendix.md](./openvpn-nks-operations-appendix.md)로 운영 자동화, 인증서 교체, 트러블슈팅 흐름을 정리한다.

## 5. 운영 부록 안내

- 인증서 갱신, 폐기, CRL, 운영 자동화, 트러블슈팅은 [openvpn-nks-operations-appendix.md](./openvpn-nks-operations-appendix.md)에 분리했다.
- 이 부록에는 기존 가이드의 `## 10. 인증서 갱신 / 폐기 / 교체`부터 `## 12. 트러블슈팅 체크리스트`까지를 원문 그대로 옮겼다.
- 운영 절차와 명령어도 축약하지 않았다.

## 6. 최종 권고

- 과업 검증 기준 본선은 `주 방안`
  - `NodeGroup-A`
  - `user script` 기반 자동 설치
  - `node별 고유 cert/key`
- 공공기관/실운영 기준 기본 권고안은 `추가 방안 1`
  - `Public VPC OpenVPN Server`
  - `Private VPC VPN Gateway VM(Client)`
  - `worker subnet -> gateway VM` 라우팅
  - 가능하면 `Gateway VM 2대 이상 + VIP`
- `주 방안`은 반드시 `전용 node group`에만 적용
- `추가 방안 2`는 소수 애플리케이션 예외 처리용으로만 사용
- PKI는 `CA 분리`, `leaf cert 분리`, `duplicate-cn 비활성`, `CRL 운영`, `재발급 기반 갱신` 원칙으로 간다


## 7. 참고 문서

- OpenVPN: [Routing all client traffic through VPN](https://openvpn.net/community-docs/routing-all-client-traffic--including-web-traffic--through-the-vpn.html)
- OpenVPN: [OpenVPN 2.6 Manual](https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html)
- OpenVPN: [Hardening OpenVPN Security](https://openvpn.net/community-docs/hardening-openvpn-security.html)
- Easy-RSA: [Easy-RSA Home](https://easy-rsa.readthedocs.io/en/latest/)
- Easy-RSA: [Intro to PKI](https://easy-rsa.readthedocs.io/en/latest/intro-to-PKI/)
- Kubernetes: [Sidecar Containers](https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/)
- Kubernetes: [Pods and shared network namespace](https://kubernetes.io/docs/concepts/workloads/pods/)
- Kubernetes: [Configure a Security Context](https://kubernetes.io/docs/tasks/configure-pod-container/security-context/)
- NHN Cloud: [NKS User Script / Default Route Settings](https://docs.nhncloud.com/en/Container/NKS/en/user-guide/)
- NHN Cloud: [Peering Gateway Console Guide](https://docs.nhncloud.com/en/Network/Peering%20Gateway/en/console-guide/)
- NHN Cloud: [VPC Console Guide](https://docs.nhncloud.com/en/Network/VPC/en/console-guide/)
- NHN Cloud: [Network Interface / Source-Target Check / VIP](https://docs.nhncloud.com/en/Network/Network%20Interface/en/console-guide/)
