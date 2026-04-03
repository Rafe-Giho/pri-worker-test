# Decisions

## 결정 사항

### 1. OpenVPN은 필수 수단으로 본다

- 이유: 이번 과업은 단순 인터넷 통신이 아니라 `OpenVPN을 통한 외부 통신 방법 탐구 및 숙달`이 목적이다.
- 영향: 단순 proxy나 일반 egress gateway만으로 끝내지 않는다.

### 2. OpenVPN 서버는 Public VPC에 둔다

- 이유: 인터넷 outbound가 쉬워야 하고, Private VPC client가 peering으로 private IP에 붙는 구조가 가장 단순하다.

### 3. CA 서버는 Private VPC의 별도 VM으로 둔다

- 이유: CA private key를 데이터 플레인 장비와 분리해야 한다.
- 영향: OpenVPN 서버와 CA 역할을 분리한다.

### 4. 세 가지 방안을 모두 유지한다

- `주 방안`: worker node에 OpenVPN client
- `추가 방안 1`: VPN Gateway VM
- `추가 방안 2`: Pod sidecar

이유:

- PoC와 실운영의 최적안이 다를 수 있다.
- 보고/비교 자료로도 세 방안이 필요하다.

### 5. 인증서는 공유보다 개체별 발급을 원칙으로 한다

- 적용 대상:
  - worker node
  - gateway VM
  - sidecar workload
- 이유: 폐기 단위, 감사 추적성, 공공기관 대응

### 6. bundle 내부 파일명은 고정한다

- `ca.crt`
- `client.crt`
- `client.key`
- `tls-crypt.key`

이유:

- client config 템플릿을 공통으로 재사용할 수 있다.
- 개체 식별은 tar.gz 이름과 cert CN으로 별도 관리한다.

### 7. 자동 발급과 사전 발급을 구분한다

- 현재 문서에는 `Issuer API 설계`와 `최소 구현 기준`이 있다.
- 실제 자동 발급 서버 구현은 아직 없다.

영향:

- 지금 상태에서는 `사전 발급 bundle 다운로드`가 기본이다.
- autoscale까지 운영하려면 `Issuer API` 또는 동등한 발급 자동화가 필요하다.

### 8. 자동화 문서의 패키지 설치 명령은 `apt-get` 기준으로 쓴다

- 이유: 스크립트/운영 자동화에 더 적합하다.
