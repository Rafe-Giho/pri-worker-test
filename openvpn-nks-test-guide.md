# NKS OpenVPN 테스트 가이드

이 문서는 `주 방안 / NodeGroup-A / user script` 기준으로, **테스트용 NKS 생성과 테스트용 Pod 검증**만 따로 정리한 문서다.

범위:

- `Private NKS` 생성
- `NodeGroup-A`에 OpenVPN client 자동 설치
- `node egress` 검증
- 테스트용 Pod 배포
- `pod DNS`, `pod curl google.com` 검증

범위 밖:

- PKI 상세 구축
- OpenVPN 서버 상세 구축
- Gateway VM 방식
- sidecar 방식
- 인증서 갱신 / 폐기 운영 절차

상세 원문은 아래 문서를 기준으로 한다.

- [openvpn-nks-build-guide.md](./openvpn-nks-build-guide.md)
- [openvpn-nks-implementation-appendix.md](./openvpn-nks-implementation-appendix.md)
- [openvpn-server-build-guide.md](./openvpn-server-build-guide.md)
- [openvpn-nks-operations-appendix.md](./openvpn-nks-operations-appendix.md)
- [openvpn-nks-troubleshooting-guide.md](./openvpn-nks-troubleshooting-guide.md)

## 1. 시작 전 완료 조건

아래는 **클러스터 만들기 전에** 끝나 있어야 한다.

1. `Public VPC OpenVPN Server` 구축 완료
2. `CA / Bootstrap Server` 구축 완료
3. node runtime bundle, worker bundle, bootstrap endpoint 준비 완료
4. `Public VPC`와 `Private VPC` peering 및 route 완료
5. `Private NKS`에서 test image를 pull할 계획이면 `Private DNS` 완료

`Private DNS`를 쓰는 경우 최소 보장:

- `private-<REGISTRY_ID>-kr1-registry.container.nhncloud.com -> <NCR_SGW_IP>`
- `kr1-api-object-storage.nhncloudservice.com -> <OBS_SGW_IP>`

중요:

- test Pod 이미지 pull은 `Pod`가 아니라 `node의 kubelet/containerd`가 수행한다.
- 따라서 `hostAliases`로는 image pull 문제를 해결할 수 없다.

## 2. 테스트용 NKS 생성 기준

이번 테스트는 `NodeGroup-A`만 쓴다.

권장:

- `Private NKS`
- 전용 node group 1개
  - 예: `plain-vpn-client`
- 초기 node 수: `1`
- 다른 workload와 섞지 않음

이유:

- OpenVPN client가 node 단위로 붙는다.
- image pull, DNS, kubelet 경로까지 같이 영향받으므로 공용 node group에 섞지 않는 편이 안전하다.

## 3. NodeGroup-A user script

운영 기준으로는 긴 inline script보다 **짧은 launcher + bootstrap 서버의 2차 스크립트** 방식이 낫다.

전제:

- `CA / Bootstrap Server`에 `worker-egress-bootstrap.sh`가 이미 배치돼 있어야 한다.
- 상세 내용은 [openvpn-nks-implementation-appendix.md](./openvpn-nks-implementation-appendix.md)의 `7.5.1`을 따른다.
- fresh node 기준으로 `bootstrap-root-ca.pem`은 2차 스크립트가 먼저 받아온다.
- 2차 스크립트를 다시 올릴 때는 `sudo rm -f /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh` 후 같은 경로에 다시 `tee`로 배치하면 된다.

NKS node group에 넣는 launcher 예시:

```bash
#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/ovpn-user-script.log) 2>&1

BOOTSTRAP_IP="172.16.200.44"
BOOTSTRAP_USER="bootstrap"
BOOTSTRAP_PASSWORD="<BOOTSTRAP_PASSWORD>"
BOOTSTRAP_BASE_URL="https://${BOOTSTRAP_IP}/ovpn"

curl -k -fsSL -u "${BOOTSTRAP_USER}:${BOOTSTRAP_PASSWORD}" \
  -o /var/tmp/worker-egress-bootstrap.sh \
  "${BOOTSTRAP_BASE_URL}/packages/worker-egress-bootstrap.sh"

chmod 0700 /var/tmp/worker-egress-bootstrap.sh

BOOTSTRAP_IP="${BOOTSTRAP_IP}" \
BOOTSTRAP_USER="${BOOTSTRAP_USER}" \
BOOTSTRAP_PASSWORD="${BOOTSTRAP_PASSWORD}" \
NODE_ID="ovpn-node-ng-a-01" \
OPENVPN_SERVER_IP="<OPENVPN_SERVER_PRIVATE_IP>" \
OPENVPN_SERVER_PORT="1194" \
OPENVPN_PROTO="udp" \
PRIVATE_VPC_NETWORK="<PRIVATE_VPC_NETWORK>" \
PRIVATE_VPC_NETMASK="<PRIVATE_VPC_NETMASK>" \
PUBLIC_VPC_NETWORK="<PUBLIC_VPC_NETWORK>" \
PUBLIC_VPC_NETMASK="<PUBLIC_VPC_NETMASK>" \
NKS_POD_NETWORK="<NKS_POD_NETWORK>" \
NKS_POD_NETMASK="<NKS_POD_NETMASK>" \
NKS_SERVICE_NETWORK="<NKS_SERVICE_NETWORK>" \
NKS_SERVICE_NETMASK="<NKS_SERVICE_NETMASK>" \
EGRESS_DNS_1="<APPROVED_DNS_1>" \
EGRESS_DNS_2="<APPROVED_DNS_2>" \
PRIVATE_DNS_SERVER="<PRIVATE_DNS_SERVER>" \
PRIVATE_DNS_ROUTE_DOMAINS="openstacklocal container.nhncloud.com nhncloudservice.com" \
SERVICE_GATEWAY_NEXT_HOP="" \
SERVICE_GATEWAY_BYPASS_IPS="" \
RUNTIME_BUNDLE="node-runtime-ubuntu2204-amd64.tar.gz" \
/var/tmp/worker-egress-bootstrap.sh
```

메모:

- 이 테스트 문서는 `Private DNS가 이미 구성된 상태`를 전제로 한다.
- 따라서 `NCR/OBS`용 `/etc/hosts` fallback은 넣지 않는다.
- 2차 스크립트는 `dpkg -i` 후 `openvpn`, `curl`, `ca-certificates`가 이미 설치됐으면 `apt-get -f install`을 더 진행하지 않는다.
- 운영형 DNS는 `eth0=Private DNS`, `tun0=외부 DNS`로 split DNS를 전제로 한다.

## 4. Node egress 검증

클러스터 생성 후 먼저 **node에서만** 확인한다.

```bash
systemctl status openvpn-client@worker-egress --no-pager
ip addr show tun0
ip route
resolvectl status
resolvectl query www.google.com
curl -I --max-time 10 https://www.google.com
curl --max-time 10 https://ifconfig.me
```

성공 기준:

- `openvpn-client@worker-egress`가 `active (running)`
- `tun0`에 `10.8.0.x`
- `resolvectl query www.google.com` 성공
- `curl -I https://www.google.com` 성공
- `curl https://ifconfig.me`가 OpenVPN 서버 공인 IP로 보임

중요:

- 여기까지는 `node egress` 성공이다.
- 아직 `pod egress` 성공을 뜻하지는 않는다.

## 5. 테스트용 Pod 이미지 준비

테스트용 Pod 이미지가 `Private NKS`에서 pull 가능해야 한다.

권장:

- 이미지 push: `Public URI`
- 이미지 pull: `Private URI`

예:

- push: `c0978417-kr1-registry.container.nhncloud.com/ta-sgh-ncr/pod-egress-test:1.0.0`
- pull: `private-c0978417-kr1-registry.container.nhncloud.com/ta-sgh-ncr/pod-egress-test:1.0.0`

`docker-registry` secret 예시:

```bash
kubectl create namespace egress-test

kubectl -n egress-test create secret docker-registry registry-credential \
  --docker-server=private-c0978417-kr1-registry.container.nhncloud.com/ta-sgh-ncr \
  --docker-username=<User_Access_Key_ID> \
  --docker-password=<Secret_Access_Key>
```

## 6. 테스트용 Pod 배포

테스트 Pod는 **VPN이 적용된 node**에만 올라가게 한다.

예시:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pod-egress-test
  namespace: egress-test
spec:
  nodeName: <VPN_APPLIED_NODE_NAME>
  imagePullSecrets:
    - name: registry-credential
  containers:
    - name: test
      image: private-c0978417-kr1-registry.container.nhncloud.com/ta-sgh-ncr/pod-egress-test:1.0.0
      imagePullPolicy: Always
      command: ["sh", "-c", "sleep 365d"]
  restartPolicy: Never
```

적용:

```bash
kubectl apply -f pod-egress-test.yaml
kubectl get pod -n egress-test -o wide
kubectl describe pod -n egress-test pod-egress-test
```

## 7. Pod 검증 순서

순서는 아래대로 본다.

1. cluster DNS
2. external DNS
3. HTTP egress

명령:

```bash
kubectl exec -n egress-test -it pod-egress-test -- nslookup kubernetes.default.svc.cluster.local
kubectl exec -n egress-test -it pod-egress-test -- nslookup google.com
kubectl exec -n egress-test -it pod-egress-test -- curl -I https://www.google.com
kubectl exec -n egress-test -it pod-egress-test -- curl https://ifconfig.me
```

성공 기준:

- `nslookup kubernetes.default.svc.cluster.local` 성공
- `nslookup google.com` 성공
- `curl -I https://www.google.com` 성공
- `curl https://ifconfig.me`가 OpenVPN 서버 공인 IP로 보임

## 8. 실패 시 참고 문서

- `ImagePullBackOff`, `split DNS`, `CoreDNS`, `pod DNS`, `MTU`, `route` 문제는 [openvpn-nks-troubleshooting-guide.md](./openvpn-nks-troubleshooting-guide.md)에서 본다.
- 이 테스트 문서에서는 `node -> image pull -> pod DNS -> pod HTTP` 순서만 유지하고, 실패 원인 분리는 별도 문서로 처리한다.

## 9. 이 문서의 해석 기준

이 테스트 문서를 따라도 아래처럼 봐야 한다.

- `node` 검증 성공
  - OpenVPN 연결과 node outbound는 성공
- `pod` 검증 성공
  - 그 위에 image pull, CoreDNS, pod egress까지 성공

즉:

- `node 성공 == pod 성공`은 아니다
- 항상 `node`를 먼저 통과시키고, 그 다음 `pod`를 본다
