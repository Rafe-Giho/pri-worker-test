# NKS OpenVPN 트러블슈팅 가이드

- 이 문서는 [openvpn-nks-build-guide.md](./openvpn-nks-build-guide.md)의 트러블슈팅 부록이다.
- `NodeGroup-A / user script / worker-egress` 기준 원인 분리를 먼저 정리하고, 필요 시 gateway VM / sidecar로 확장한다.
- 현재 운영 기본값은 `split DNS`다.
  - `eth0 -> Private DNS`: `openstacklocal`, `container.nhncloud.com`, `nhncloudservice.com`
  - `tun0 -> 외부 DNS`: 그 외 public name

## 1. 먼저 보는 순서

항상 아래 순서로 자른다.

1. `user script`가 실제로 들어갔는지
2. bootstrap 서버에서 2차 스크립트를 받았는지
3. runtime / client bundle 배치가 끝났는지
4. `openvpn-client@worker-egress`가 떴는지
5. `tun0`와 node egress가 되는지
6. `Private URI` image pull이 되는지
7. pod DNS / pod HTTP가 되는지

`node 성공 == pod 성공`으로 보면 안 된다.

## 2. User Script / Bootstrap 문제

확인:

```bash
sudo wc -c /var/tmp/userscript.sh /var/tmp/userscript_v2.sh 2>/dev/null
sudo sed -n '1,160p' /var/tmp/userscript_v2.sh 2>/dev/null
sudo tail -n 100 /var/log/ovpn-user-script.log
```

판단:

- `/var/tmp/userscript.sh = 1 byte`
  - NKS user-data 전달 문제일 가능성이 높다
- `/var/tmp/userscript_v2.sh`는 있는데 로그가 거의 없다
  - cloud-init 실행 문제 또는 부팅 시점 실패 가능성이 높다
- `curl -k ... worker-egress-bootstrap.sh` 단계에서 실패
  - bootstrap 서버 접근, Basic Auth, nginx 문제
- `required runtime packages are still missing...`
  - 2차 runtime 설치 단계 실패

bootstrap 서버 실제 파일도 같이 본다.

```bash
sudo grep -nE 'PRIVATE_DNS_SERVER|resolvectl dns eth0|have_runtime_pkgs' /srv/bootstrap/ovpn/packages/worker-egress-bootstrap.sh
```

## 3. 연결 자체가 안 될 때

점검:

```bash
systemctl status openvpn-client@worker-egress --no-pager
journalctl -u openvpn-client@worker-egress -n 100 --no-pager
ip addr show tun0
```

원인 후보:

- `UDP/<OPENVPN_SERVER_PORT>` 보안 그룹 미허용
- peering route 문제
- `ca/cert/key/tls-crypt` 불일치
- `remote-cert-tls server` 검증 실패
- `crl.pem`으로 차단

## 4. 연결은 되는데 Node 인터넷이 안 될 때

점검:

```bash
ip route
resolvectl status
resolvectl query www.google.com
curl -I --max-time 10 https://www.google.com
curl --max-time 10 https://ifconfig.me
```

판단:

- `resolvectl query www.google.com` 실패
  - DNS 문제를 먼저 본다
- `query`는 되는데 `curl` timeout
  - 서버 NAT / forwarding / MTU / route를 본다

서버 측 점검:

```bash
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S
sudo iptables -S FORWARD
```

필수:

- `net.ipv4.ip_forward = 1`
- `POSTROUTING MASQUERADE`
- `FORWARD` 허용

## 5. Split DNS가 의도대로 안 될 때

정상 기대:

```bash
resolvectl query private-<REGISTRY_ID>-kr1-registry.container.nhncloud.com
resolvectl query kr1-api-object-storage.nhncloudservice.com
resolvectl query www.google.com
```

- `private-...` -> `link: eth0`
- `kr1-api-object-storage...` -> `link: eth0`
- `www.google.com` -> `link: tun0`

현재 node에 실제로 적용된 설정 확인:

```bash
resolvectl status
sudo grep -nE 'PRIVATE_DNS_SERVER|PRIVATE_DNS_ROUTE_DOMAINS' /var/tmp/userscript_v2.sh
sudo grep -nE 'PRIVATE_DNS_SERVER|PRIVATE_DNS_ROUTE_DOMAINS|resolvectl dns eth0|resolvectl domain eth0' /var/tmp/worker-egress-bootstrap.sh
sudo grep -nE 'PRIVATE_DNS_SERVER|resolvectl dns eth0|resolvectl domain eth0' /var/log/ovpn-user-script.log
```

판단:

- `PRIVATE_DNS_SERVER`가 1차 launcher에 없음
  - node group user script가 예전 버전
- `worker-egress-bootstrap.sh`에 `resolvectl dns eth0`가 없음
  - bootstrap 서버 2차 파일이 예전 버전
- 둘 다 있는데 `private-...`가 계속 `link: tun0`
  - `Private DNS zone / VPC 연결` 문제 가능성이 높다

`/etc/resolv.conf`는 직접 수정하지 않는다.

## 6. Private NKS + Private URI image pull이 안 될 때

먼저 node에서:

```bash
getent hosts private-<REGISTRY_ID>-kr1-registry.container.nhncloud.com
getent hosts kr1-api-object-storage.nhncloudservice.com
resolvectl query private-<REGISTRY_ID>-kr1-registry.container.nhncloud.com
```

정상 기대:

- `Private URI -> NCR SGW IP`
- `Object Storage 도메인 -> OBS SGW IP`
- `Private URI`는 `link: eth0`

그다음 Pod:

```bash
kubectl describe pod -n <NS> <POD>
```

실패 예시:

- `dial tcp 10.x.x.x:443: i/o timeout`
  - 보통 `Private URI`가 `tun0` DNS로 풀린 경우가 많다
- `401 Unauthorized`
  - 네트워크는 정상이고 인증만 빠진 상태다

`SERVICE_GATEWAY_BYPASS_IPS`는 1차 해결책이 아니다.
- 먼저 `name resolution`
- 그다음 route
순서로 본다.

## 7. NKS 내부 통신이 깨질 때

점검:

```bash
ip route
kubectl get svc -A
kubectl get pod -A -o wide
```

확인:

- `NKS Pod CIDR` bypass
- `NKS Service CIDR` bypass
- `Private VPC CIDR` bypass
- `Public VPC CIDR` bypass

증상:

- `ClusterIP` 접근 실패
- `kubernetes.default.svc.cluster.local` 실패
- Pod 간 통신 실패

## 8. Pod DNS / Pod HTTP가 안 될 때

순서:

1. `nslookup kubernetes.default.svc.cluster.local`
2. `nslookup google.com`
3. `curl -I https://www.google.com`

점검:

```bash
kubectl -n kube-system get pods -o wide -l k8s-app=kube-dns
kubectl -n kube-system get configmap coredns -o yaml
```

판단:

- `kubernetes.default.svc.cluster.local` 실패
  - `CoreDNS` 문제부터 본다
- cluster DNS는 되는데 `google.com` 실패
  - `CoreDNS upstream` 또는 외부 DNS 경로 문제
- `nslookup google.com`은 되는데 `curl`만 실패
  - node egress / NAT / MTU를 본다

## 9. MTU 문제

증상:

- 일부 API만 timeout
- 큰 payload에서만 실패

대응:

```bash
tracepath <DESTINATION>
sudo tcpdump -ni tun0
```

- `mssfix 1360`부터 테스트
- 필요 시 `tun-mtu` 조정
