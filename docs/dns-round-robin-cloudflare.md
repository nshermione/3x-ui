# 3x-ui — DNS Round-Robin (Cloudflare) cho từng cụm vùng

## Mục tiêu

- 9 nodes, 3 vùng (**VN / SING / HK**), mỗi vùng 3 nodes.
- Panel: **1 master + multi-node**.
- Client: **v2box** — subscription chỉ hiện **3 dòng** (1 hostname / vùng).
- Khi user chọn `VN`, DNS (Cloudflare) trả 1 trong 3 IP của cụm VN → client nối **1 hop** thẳng vào node đó.
- **Không** đi qua entry relay / Xray balancer → **không** nhân đôi băng thông server như kiến trúc 2 hop.

So sánh nhanh với `docs/multi-node-load-balancing.md`:

| | DNS RR (file này) | Xray balancer (file kia) |
|---|---|---|
| Số hop | **1** (client → node cuối) | **2** (client → cửa → backend) |
| Băng thông VPS | Bình thường | Entry + backend cùng chuyển data (~gấp đôi) |
| Ai chia tải | DNS / client chọn IP | Xray `roundRobin` trên entry |
| Failover khi 1 IP chết | DNS vẫn có thể trả IP chết (xem bên dưới) | `leastPing` thông minh hơn `roundRobin` |
| Client trên cụm | **Phải có trên mọi node trong cụm** | Chỉ cần trên inbound cửa |

---

## Ý tưởng

```text
vn.example.com     → A → IP VN-1
                   → A → IP VN-2
                   → A → IP VN-3

sing.example.com   → A → IP SING-1, SING-2, SING-3
hk.example.com     → A → IP HK-1, HK-2, HK-3

v2box sub chỉ có 3 link:
  VN   = vn.example.com:443   (+ UUID, Reality, …)
  SING = sing.example.com:443
  HK   = hk.example.com:443
```

User chọn `VN` → resolver nhận **một** (hoặc vài) A record → TCP tới IP đó → Xray trên node đó terminate VPN → ra Internet.

---

## Cloudflare: DNS only, không proxy cam

Với VLESS / REALITY / phần lớn inbound “raw” của 3x-ui:

1. Vào Cloudflare → DNS → Records.
2. Tạo **nhiều record cùng tên**, mỗi record 1 IP node:

| Type | Name | Content | Proxy status |
|---|---|---|---|
| A | `vn` | `x.x.x.1` | **DNS only** (mây xám) |
| A | `vn` | `x.x.x.2` | **DNS only** |
| A | `vn` | `x.x.x.3` | **DNS only** |

3. Làm tương tự `sing`, `hk`.

**Bắt buộc mây xám (DNS only).**  
Mây cam (Proxied) đi qua CDN HTTP(S) của Cloudflare — **không** dùng cho REALITY / VLESS TCP thẳng. Chỉ cân nhắc proxied nếu anh cố ý chạy WebSocket/gRPC/HTTPS trên port CF hỗ trợ (setup khác, không phải RR thuần cho Reality).

TTL: để Auto, hoặc 60–300s nếu anh hay rút IP chết.

---

## “Round-robin” của Cloudflare nghĩa là gì?

- Nhiều A record cùng tên → Cloudflare DNS trả tập IP (thứ tự có thể xoay).
- Client / OS / app chọn **một** IP để nối — phân tải **xấp xỉ**, không đảm bảo chia đều tuyệt đối.
- Đây **không** phải Cloudflare Load Balancing (sản phẩm trả phí có health check). DNS RR **không** tự bỏ IP đang down.

Khi 1 node chết: một phần user vẫn resolve trúng IP chết → fail tới khi anh xóa/disable record hoặc node sống lại.

(Tuỳ chọn nâng cao: Cloudflare **Load Balancing** có health check — ngoài scope tối thiểu của file này.)

---

## Setup trên 3x-ui (master panel)

### 1) Mỗi vùng: 3 inbound giống nhau (1 inbound / node)

Ví dụ cụm VN — tạo 3 inbound:

| Remark (nội bộ panel) | Deploy to | Port | Protocol / Reality / keys |
|---|---|---|---|
| `vn-node-1` | `vietnam-1` | `443` | **Giống hệt nhau** |
| `vn-node-2` | `vietnam-2` | `443` | **Giống hệt nhau** |
| `vn-node-3` | `vietnam-3` | `443` | **Giống hệt nhau** |

Bắt buộc khớp trên cả cụm:

- Port, protocol, flow
- REALITY / TLS: cùng `privateKey`–`publicKey`, `shortId`, SNI / `serverNames`, spider, …
- Transport (tcp / xhttp / …)

**Share address (quan trọng):**

- Không để client lấy IP từng node.
- Set địa chỉ share / strategy sao cho link xuất ra host = `vn.example.com` (tên DNS RR), **không** phải IP `Deploy to`.
- Trong form inbound (Basics): dùng cách panel cho phép gán share host (custom address / remark host — tùy UI bản anh đang chạy). Mục tiêu: link sub có `address = vn.example.com`.

Lặp lại cho SING / HK với hostname `sing.example.com`, `hk.example.com`.

### 2) Clients (100 user) — phải có mặt trên mọi node trong cụm

DNS có thể trả bất kỳ IP nào trong cụm → **mọi node đó phải auth được cùng UUID**.

Trên trang **Clients**, mỗi user bán hàng:

- **Attached inbounds** phải gồm **cả 3 inbound** của VN + 3 SING + 3 HK **nếu** anh muốn user vào được cả 3 vùng đủ 3 máy;  
  **hoặc** tối thiểu: đủ 3 inbound của mỗi vùng user được phép dùng.

Ví dụ user được dùng cả 3 vùng → attach **9 inbound** (3×3). Auth đúng trên mọi IP DNS trả về.

> Đây là điểm khác kiến trúc balancer: DNS RR **không** tránh được việc user tồn tại trên mọi node trong pool.

### 3) Subscription chỉ hiện 3 dòng trên v2box

Nếu attach 9 inbound, sub mặc định có thể ra **tới 9 link** (kể cả khi address đều là hostname vùng).

Cách xử lý thực tế (chọn 1):

**Cách A — Ưu tiên (đơn giản, đúng 3 dòng):**  
Dùng **1 inbound “canonical” / vùng** để xuất sub (chỉ attach 3 inbound cửa/canonical vào góc nhìn sub) — **nhưng** vẫn phải đảm bảo 2 node còn lại có cùng client.

Với model Clients của 3x-ui v3: **attach = vừa có mặt trên inbound, vừa ra sub**. Không có nút “có trên node nhưng ẩn khỏi sub” trên từng inbound.

→ Muốn đúng 3 dòng **và** đủ auth 3 IP, anh cần thêm một trong các hướng:

1. **Sub converter / filter** (ngoài panel): lấy sub gốc, gộp/dedupe theo `host:port:uuid`, chỉ giữ 1 link / vùng.  
2. **Chấp nhận tạm** nhiều link trùng hostname trên v2box (xấu UX).  
3. **Đồng bộ client bằng API/script** lên inbound không gắn sub — phức tạp hơn, dễ lệch panel.

**Cách B — Thực dụng nếu v2box gộp link trùng:**  
Cả 3 inbound vùng dùng **cùng** share host + cùng UUID + cùng remark hiển thị; một số app gộp trùng, một số vẫn hiện 3 dòng — **phải test trên v2box** của anh.

Khuyến nghị: test sớm 1 user + 1 vùng trước khi gắn 100 client.

### 4) Không cần Outbound / Balancer / Routing relay

Kiến trúc này **không** dùng Xray balancer giữa các node.  
Outbound mặc định `direct` / `freedom` trên mỗi node là đủ.

---

## Checklist

- [ ] Cloudflare: 3 hostname vùng, mỗi hostname 3×A record, **DNS only**.
- [ ] 3 inbound / vùng, Deploy to đúng 3 node, config (port/keys) giống nhau.
- [ ] Share address = hostname DNS (`vn.example.com`, …), không lộ IP từng node trên sub.
- [ ] User attach đủ inbound trong cụm (auth mọi IP).
- [ ] v2box chỉ còn ~3 dòng (hoặc đã có plan dedupe/converter).
- [ ] Tắt 1 node thử: một phần connect fail — xóa A record IP chết để hết fail.

---

## Kiểm tra nhanh

```bash
# Phải thấy 3 IP
dig +short vn.example.com A

# Lặp lại vài lần / máy khác — thứ tự IP có thể đổi
```

Trên v2box: import sub → chọn `VN` → connect. Trên panel, online/traffic xuất hiện **luân phiên** trên các node VN (không đảm bảo đều tuyệt đối).

---

## Pitfall

1. **Mây cam** → Reality/VLESS raw hỏng hoặc hành vi lạ. Luôn DNS only.  
2. **Config lệch** giữa 3 node (shortId / pubkey / port) → lúc được lúc không tùy IP DNS trả.  
3. **User chỉ attach 1 inbound** trong cụm → DNS trúng node khác → auth fail.  
4. **Sub ra 9 nodes** → quên dedupe / gắn thừa inbound vào góc xuất sub.  
5. **Node chết vẫn còn A record** → RR không tự failover.  
6. IPv6: nếu thêm AAAA, client có thể ưu tiên IPv6 — chỉ thêm khi cả cụm sẵn sàng.

---

## Khi nào chọn DNS RR vs Xray balancer?

- Chọn **DNS RR (file này)** khi: muốn **1 hop**, tiết kiệm bandwidth/latency, chấp nhận sync client trên mọi node + failover DNS thủ công.  
- Chọn **Xray balancer** khi: muốn 100 user chỉ nằm ở inbound cửa, panel tự chia tải/relay, chấp nhận tốn thêm hop + bandwidth.

---

## Ghi chú mở (thảo luận chỉnh sửa)

- [ ] Domain thật cho `vn` / `sing` / `hk`.
- [ ] Protocol cụ thể (VLESS+REALITY?).
- [ ] Cách anh chọn để sub chỉ 3 dòng (converter / test dedupe v2box / khác).
- [ ] Có dùng Cloudflare Load Balancing (có health check) sau này không?

## Tham chiếu

- Kiến trúc 2 hop + Xray balancer: `docs/multi-node-load-balancing.md`
