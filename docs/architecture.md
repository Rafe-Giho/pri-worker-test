# Architecture

## 전체 구조

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

## 방안별 데이터 경로

### 주 방안

```text
Pod -> Worker Node(OpenVPN Client) -> tun0 -> OpenVPN Server -> Internet Gateway -> External Service
```

### 추가 방안 1

```text
Pod -> Worker Node -> VPC Route -> VPN Gateway VM(OpenVPN Client) -> tun0 -> OpenVPN Server -> Internet Gateway -> External Service
```

### 추가 방안 2

```text
Pod(App + OpenVPN Sidecar) -> Pod netns route -> tun0 -> OpenVPN Server -> Internet Gateway -> External Service
```

## 원리

- `Peering`: Private VPC에서 Public VPC의 OpenVPN 서버 private IP로 접근하기 위한 VPC 간 사설 연결
- `OpenVPN`: client와 server 사이에 암호화된 터널 생성
- `Routing`: 어떤 트래픽을 `eth0`로 남기고 어떤 트래픽을 `tun0`로 보낼지 결정
- `NAT`: OpenVPN 서버가 client 트래픽을 인터넷 방향으로 `SNAT/MASQUERADE`
- `DNS`: `curl google.com` 성공을 위해 이름 해석 경로가 먼저 정상이어야 함

## 핵심 설계 포인트

- OpenVPN 서버 endpoint는 터널 밖 경로로 남겨야 한다.
- 내부 통신용 CIDR은 bypass route로 유지해야 한다.
- `NodeGroup-B`는 별도 subnet/route domain이 가장 안전하다.
- CA 서버는 NKS 안이 아니라 `Private VPC`의 별도 VM이다.
