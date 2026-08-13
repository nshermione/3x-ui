# 3x-ui — Multi-node Load Balancing (Subscription chỉ hiện 3 nodes)

## Mục tiêu

- Có **9 nodes** (3x-ui v3.6.0), chia 3 khu vực: **VN / SING / HK**, mỗi khu **3 nodes**.
- Panel: **1 master + multi-node**.
- Client: **v2box** (subscription).
- Subscription chỉ hiện **3 dòng**: `VN`, `SING`, `HK`.
- Khi user chọn 1 dòng (vd `VN`), traffic được **round-robin** sang 3 server thật trong khu vực đó.

## Kiến trúc

Balancer của 3x-ui / Xray hoạt động ở tầng **outbound**, không phải “chọn node trong danh sách Nodes”.

```text
v2box subscription chỉ thấy:
  VN   → inbound cửa trên node VN-entry
  SING → inbound cửa trên node SING-entry
  HK   → inbound cửa trên node HK-entry

Khi chọn VN:
  Client → VN-entry (inbound cửa)
        → routing → balancer-vn (roundRobin)
        → outbound vn-1 / vn-2 / vn-3
        → 3 server backend VN
```

### Vai trò từng node (mỗi vùng)

| Vai trò | Ví dụ VN | Hiện trên v2box? |
|---|---|---|
| Entry (cửa) | `VN-1` | Có — remark `VN` |
| Backend | `VN-1`, `VN-2`, `VN-3` | Không |

> Entry là 1 trong 3 node của vùng (khuyến nghị). Cả 3 node đều chạy inbound backend; chỉ entry chạy thêm inbound cửa cho user.

> Đây là **relay 2 hop** (client → entry → backend). Latency tăng nhẹ; đổi lại client chỉ thấy 3 nodes và panel chia tải.

---

## Quan trọng: multi-node ≠ tự copy 100 client sang mọi node

**Anh không phải tạo lại 100 client khi thêm node.**

Trong 3x-ui multi-node:

- Mọi inbound / client / outbound / balancer đều tạo trên **Control Panel (master)**.
- Mỗi **inbound** chọn **Node** = server nào chạy inbound đó (panel đẩy config xuống node) — không phải login từng máy.
- Danh sách user (100 client) chỉ thuộc inbound đó — panel **không** tự nhân bản 100 user sang node mới để load-balance.
- Multi-node = quản lý nhiều server từ 1 panel, **không** phải “1 inbound / 1 list user chạy song song trên 3 máy”.

Trong kiến trúc balancer này có **2 loại client hoàn toàn khác nhau**:

| Loại | Attached inbounds | Số lượng | Mục đích |
|---|---|---|---|
| **User bán hàng** | Chỉ 3 inbound cửa: `VN` / `SING` / `HK` | 100 (hay N user) | Auth user thật, quota, expiry, subscription → hiện trên v2box |
| **Client kỹ thuật (relay)** | Chỉ các inbound backend | **1 client / vùng** (UUID dùng chung) | Để outbound của entry kết nối vào backend — **không** dùng sub_id của user |

### 3x-ui v3.x: không có nút “tắt Sub” trên Inbound

Trong form **Modify Inbound** (Basics) anh thấy:

- `Subscription sort order` = thứ tự sắp xếp link **khi inbound đã nằm trong sub** — **không** phải bật/tắt sub.
- Không còn toggle kiểu “Enable Sub” như bản cũ.

Cách subscription hoạt động ở v3.6:

1. Vào trang **Clients** (không phải edit inbound).
2. Mỗi user có **Sub ID** + danh sách **Attached inbounds**.
3. Link nào ra sub = các inbound mà client đó **được gắn**.

→ Muốn backend không hiện trên v2box: **đừng attach** inbound backend vào 100 user. Chỉ attach 3 inbound cửa.

Khi thêm node backend mới (vd `VN-4`):

1. Tạo 1 inbound backend, gán Node `VN-4`, kèm **1 client kỹ thuật** (cùng UUID vùng VN).
2. Thêm outbound `vn-4` + đưa vào selector của `balancer-vn`.
3. **Không attach** inbound mới vào 100 user bán hàng.

100 user vẫn chỉ attach 3 inbound cửa — thêm/xóa/gia hạn **một chỗ**.

---

## Giả định / quyết định đã chốt

1. **1 panel master + multi-node** (không phải 9 panel độc lập).
2. Client **v2box** — không cần cấu hình balancer phía client; chỉ import subscription.
3. Strategy balancer: **roundRobin** (có thể đổi later sang `leastPing` / `leastLoad` nếu cần failover thông minh hơn).

---

## Bước 1 — Backend inbound (tạo trên master panel, gán Node)

> Mục đích bước này: tạo **cổng kỹ thuật** để entry relay vào — **không** phải tạo 100 user.
>
> **Toàn bộ thao tác làm trên Control Panel (master).** Không cần SSH / mở panel riêng từng node.
> Khi tạo inbound, chọn field **Node** = server nào sẽ chạy inbound đó. Panel sync config xuống node.

Trong master panel → **Inbounds** → tạo inbound backend cho từng server trong vùng (vd VN cần 3 inbound, mỗi cái chọn Node khác nhau):

- Protocol thống nhất trong toàn hệ thống (khuyến nghị **VLESS**).
- Port riêng (vd `20443`) — **không** trùng port inbound cửa.
- Tạo / gắn **1 client kỹ thuật** (1 UUID) vào các inbound backend — **không** gắn 100 user vào đây.
- UUID kỹ thuật: **cùng 1 UUID** cho cả 3 (hoặc N) backend trong **một vùng** (outbound entry dùng UUID này).
- Remark: `VN-backend-1`, `VN-backend-2`, `VN-backend-3` (tương tự SING/HK).
- Field **Deploy to / Node**: chọn `VN-1` / `VN-2` / `VN-3` tương ứng.
- `Subscription sort order`: bỏ qua (backend không vào sub của user).
- **Không attach** các inbound backend vào client bán hàng (trang **Clients**).

Làm tương tự cho SING và HK (mỗi vùng 1 UUID kỹ thuật riêng cũng được).

Ghi lại cho mỗi backend (để điền outbound):

- IP / domain
- Port
- UUID kỹ thuật (relay)
- Security (TLS / REALITY / none)
- Transport (tcp / ws / xhttp / …)
- SNI / path / serviceName (nếu có)

---

## Bước 2 — Outbounds (Xray Configs → Outbounds)

Thêm outbound trỏ tới từng backend. Tag đặt rõ, ổn định:

| Tag | Address | Trỏ tới |
|---|---|---|
| `vn-1` | IP/domain VN-1 | inbound backend VN-1 |
| `vn-2` | IP/domain VN-2 | inbound backend VN-2 |
| `vn-3` | IP/domain VN-3 | inbound backend VN-3 |
| `sing-1` | … | inbound backend SING-1 |
| `sing-2` | … | … |
| `sing-3` | … | … |
| `hk-1` | … | inbound backend HK-1 |
| `hk-2` | … | … |
| `hk-3` | … | … |

Settings outbound phải **khớp 100%** inbound backend (protocol, port, UUID, TLS/REALITY, transport, SNI, path…).

Giữ outbound mặc định `direct` / `freedom` cho traffic local trên node.

> Tip: có thể làm xong VN trước (3 outbound) → test ổn → clone sang SING/HK.

---

## Bước 3 — Balancers (Xray Configs → Balancers)

| Tag | Selector | Strategy |
|---|---|---|
| `balancer-vn` | `vn-1`, `vn-2`, `vn-3` | `roundRobin` |
| `balancer-sing` | `sing-1`, `sing-2`, `sing-3` | `roundRobin` |
| `balancer-hk` | `hk-1`, `hk-2`, `hk-3` | `roundRobin` |

Selector cũng có thể dùng prefix chung (vd `vn-`) nếu panel/Xray hỗ trợ match theo prefix — miễn khớp đúng tag outbound.

---

## Bước 4 — Inbound cửa (user-facing, chỉ 3 cái vào sub)

Tạo **đúng 3** inbound. Field **Deploy to** = đúng **1 entry node / vùng** (không deploy cả 3 cửa lên cùng 1 máy, cũng không deploy cửa VN lên node SING):

| Remark (tên trên v2box) | Deploy to | Vì sao |
|---|---|---|
| `VN` | `vietnam-1` (hoặc tên node VN-entry anh đặt) | User chọn VN → kết nối IP VN; balancer trên node này relay sang 3 backend VN |
| `SING` | `singapore-1` (SING-entry) | Tương tự cho SING |
| `HK` | `hongkong-1` (HK-entry) | Tương tự cho HK |

Convention khuyến nghị: entry = node `*-1` của mỗi vùng (vd anh đang có `singapore-1`). Backend vẫn có inbound riêng trên cả `*-1`, `*-2`, `*-3`.

- Port công khai (vd `443`) — khác port backend.
- **Toàn bộ user bán hàng (100 client) chỉ Attached inbounds = 3 inbound cửa này** — không gắn backend.
- Ghi lại **inbound tag** panel tạo (vd `inbound-xxx`) để gắn routing.

---

## Bước 5 — Routing (Xray Configs → Routing)

Thêm 3 rule, đặt ưu tiên cao (phía trên các rule generic):

| Inbound Tag | Balancer Tag | Outbound Tag |
|---|---|---|
| tag của inbound `VN` | `balancer-vn` | *(để trống)* |
| tag của inbound `SING` | `balancer-sing` | *(để trống)* |
| tag của inbound `HK` | `balancer-hk` | *(để trống)* |

Khi đã set `balancerTag`, **không** set `outboundTag`.

Apply / restart Xray (hoặc để panel sync xuống nodes).

---

## Bước 6 — Subscription + v2box

1. Trang **Clients**: mỗi user bán hàng chỉ **Attached inbounds** = `VN` + `SING` + `HK` (3 inbound cửa).
2. Không gắn bất kỳ inbound `*-backend-*` nào vào user đó.
3. v2box import subscription → thấy đúng 3 dòng `VN`, `SING`, `HK`.
4. Chọn `VN` → kết nối vào VN-entry; Xray round-robin sang `vn-1` / `vn-2` / `vn-3`.

v2box không cần cấu hình balancer riêng.

---

## Checklist kiểm tra

- [ ] Subscription chỉ còn 3 dòng: VN / SING / HK.
- [ ] User bán hàng **không** attach inbound backend (kiểm tra trong Clients → Attached inbounds).
- [ ] Inbound cửa gán đúng node entry từng vùng (`Deploy to`).
- [ ] Outbound settings khớp inbound backend.
- [ ] Routing: inbound cửa → balancer đúng vùng; outbound tag để trống.
- [ ] User chọn `VN`: traffic lần lượt xuất hiện trên `vn-1` / `vn-2` / `vn-3` (không dính mãi 1 máy).
- [ ] Quota / online user: theo dõi chủ yếu ở **inbound cửa** (entry). Backend chủ yếu là relay.

---

## Pitfall thường gặp

1. **Inbound cửa gán nhầm node** → user vào node không có rule/balancer ăn.
2. **User bị attach nhầm inbound backend** → v2box hiện > 3 nodes. (Không có nút tắt Sub trên inbound; phải bỏ attach ở Clients.)
3. **Outbound sai IP / UUID / REALITY / transport** → connect được entry nhưng die / timeout ngay sau đó.
4. Config Xray global áp cho mọi node: vẫn ổn nếu default outbound là `direct` và rule chỉ match tag inbound cửa (trên backend không có tag đó thì rule không kích hoạt).
5. **roundRobin thuần**: nếu 1 backend chết, request trúng node đó có thể fail cho tới khi node lên lại. Muốn failover thông minh hơn → đổi strategy sang `leastPing` / `leastLoad` (+ observatory).

---

## Thứ tự triển khai khuyến nghị

1. Làm **VN only**: 3 backend inbound + 3 outbound + 1 balancer + 1 inbound cửa + 1 routing rule.
2. Test trên v2box (sub tạm chỉ enable `VN`).
3. Clone sang **SING**, rồi **HK**.
4. Bật đủ 3 inbound cửa trên subscription chính thức.

---

## Ghi chú mở (sẽ thảo luận chỉnh sửa)

- [ ] Chọn protocol/transport cụ thể cho cửa và backend (VLESS+REALITY? WS+TLS?).
- [ ] Entry có dùng chung port 443 với web/TLS không?
- [ ] Domain / SNI / cert strategy từng vùng.
- [ ] Có tách VPS entry riêng (không nằm trong 3 node backend) hay giữ entry = `*-1`?
- [ ] Có cần đổi sang `leastPing` sau khi roundRobin ổn không?
- [ ] Đặt tên remark cuối cùng trên v2box (vd `🇻🇳 VN` hay `VN-LoadBalance`).

---

## Tham chiếu

- Cơ chế balancer outbound của 3x-ui: thảo luận maintainer tại [MHSanaei/3x-ui#4928](https://github.com/MHSanaei/3x-ui/issues/4928).
- Phương án **1 hop** bằng DNS Round-Robin (Cloudflare): `docs/dns-round-robin-cloudflare.md`.
- Repo deploy local: `docker-compose.yml`, `install.sh` (image `ghcr.io/mhsanaei/3x-ui`).
