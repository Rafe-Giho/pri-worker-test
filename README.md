# Private NKS Worker Outbound OpenVPN PoC

NHN Cloud `Private NKS Worker Node`에서 외부 API 통신이 필요한 경우, worker node의 outbound를 `OpenVPN Server` 경유로 우회시키는 PoC 문서 저장소입니다.

최종 검증된 표준 방안은 `Worker Node 직접 OpenVPN client + Issuer API 자동 발급 + split DNS` 구성입니다.

## 목표

- `NHN Testbed`에서 `NKS` 구성
- `Worker Node`를 `PrivZone`에 배치
- `Pod`에서 `curl https://google.com` 응답 확인
- `Private URI image pull`과 public outbound를 같은 worker node에서 동시에 처리
- worker node scale-out 시 OpenVPN 인증서 자동 발급과 VPN 자동 연결 확인

## 최종 구현 요약

```text
Pod
  -> Worker Node
  -> tun0(OpenVPN client)
  -> OpenVPN Server
  -> Internet
```

worker node는 NKS `user script`로 초기화됩니다.

```text
node boot
  -> bootstrap endpoint에서 2차 스크립트 수신
  -> Issuer API node-token 호출
  -> Issuer API node-bundle 호출
  -> node 전용 OpenVPN 인증서 bundle 수신
  -> openvpn-client@worker-egress 기동
  -> split DNS 적용
```

## 기술 스택

- `NHN Cloud NKS`
- `Ubuntu 22.04 LTS`
- `OpenVPN OSS`
- `Easy-RSA`
- `FastAPI / Uvicorn`
- `systemd-resolved`
- `NHN Cloud Private DNS`
- `NCR / OBS Service Gateway`
- `NKS user script`

## 문서 구조

| 파일 | 설명 |
|---|---|
| [01-openvpn-nks-build-guide.md](./01-openvpn-nks-build-guide.md) | 전체 구조, 원리, 아키텍처, 구축 순서 |
| [02-openvpn-nks-implementation-appendix.md](./02-openvpn-nks-implementation-appendix.md) | 상세 구현 절차, user script, split DNS, 방안별 템플릿 |
| [03-openvpn-server-build-guide.md](./03-openvpn-server-build-guide.md) | Public VPC OpenVPN Server 상세 구축 |
| [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md) | Issuer API 자동 발급 구조와 구현 |
| [05-openvpn-nks-operations-appendix.md](./05-openvpn-nks-operations-appendix.md) | 운영, 갱신, 폐기, 자동화 고려사항 |
| [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md) | 장애 대응과 점검 순서 |
| [07-openvpn-nks-test-guide.md](./07-openvpn-nks-test-guide.md) | 개인 검증용 NKS 테스트 절차 |
| [report/01-과제결과-요약.md](./report/01-%EA%B3%BC%EC%A0%9C%EA%B2%B0%EA%B3%BC-%EC%9A%94%EC%95%BD.md) | 보고용 결과 요약 |
| [report/02-원리-및-통신흐름.md](./report/02-%EC%9B%90%EB%A6%AC-%EB%B0%8F-%ED%86%B5%EC%8B%A0%ED%9D%90%EB%A6%84.md) | 보고용 원리 및 통신 흐름 |

## 읽는 순서

1. [01-openvpn-nks-build-guide.md](./01-openvpn-nks-build-guide.md)
2. [02-openvpn-nks-implementation-appendix.md](./02-openvpn-nks-implementation-appendix.md)
3. [03-openvpn-server-build-guide.md](./03-openvpn-server-build-guide.md)
4. [04-openvpn-issuer-api-guide.md](./04-openvpn-issuer-api-guide.md)
5. [05-openvpn-nks-operations-appendix.md](./05-openvpn-nks-operations-appendix.md)
6. [06-openvpn-nks-troubleshooting-guide.md](./06-openvpn-nks-troubleshooting-guide.md)
7. [07-openvpn-nks-test-guide.md](./07-openvpn-nks-test-guide.md)

보고용으로는 `report/` 아래 2개 파일을 먼저 보면 됩니다.

## 검증 완료 범위

- 새 worker node scale-out 시 `Basic Auth -> node-token -> node-bundle` 자동 발급
- worker node에서 OpenVPN client 자동 기동
- `tun0` 생성 및 외부 egress 확인
- `split DNS` 적용
- `Private URI` 기반 image pull 성공
- test pod 생성 성공
- pod 내부에서 `curl https://google.com` 성공

## split DNS 핵심

현재 구성은 public outbound와 private service 접근을 나눕니다.

- `eth0`
  - `Private DNS`
  - `container.nhncloud.com`
  - `nhncloudservice.com`
  - `openstacklocal`
- `tun0`
  - public DNS
  - 일반 외부 도메인

이 구성이 필요한 이유는 `Pod curl google.com`뿐 아니라 `Private URI image pull`도 같은 worker node에서 성공해야 하기 때문입니다.

## 보안 메모

- 실제 비밀번호, Access Key, CA passphrase는 저장소에 포함하지 않습니다.
- 문서에는 구조, 템플릿, 검증 흐름만 남깁니다.
- 운영 시 민감값은 별도 보안 저장소나 제한된 운영 절차로 관리해야 합니다.

