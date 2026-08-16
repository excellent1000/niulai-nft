# 可选：在自己服务器上跑 IPFS 节点做镜像

HTTPS 直链已经够用（市场/钱包都能读）。若想同时给 IPFS 地址（更去中心化、可换 baseURI 到 ipfs://），在服务器上：

```bash
# 安装 Kubo（IPFS 官方实现）
wget https://dist.ipfs.tech/kubo/v0.34.1/kubo_v0.34.1_linux-amd64.tar.gz && tar xf kubo_*.tar.gz && sudo bash kubo/install.sh
ipfs init --profile server && (ipfs daemon &)     # 建议用 systemd 常驻
# 添加并固定（pin）目录，得到 CID
ipfs add -r -Q --cid-version 1 /var/www/niulai/img    # → IMG_CID
python pipeline/export_metadata.py --image-cid IMG_CID   # 重新生成 out/chain（image 指向 ipfs://IMG_CID/…）
ipfs add -r -Q --cid-version 1 out/chain               # → META_CID
# 合约：nft.setBaseURI("ipfs://META_CID/")  或继续用 https 直链，二者随时可切
```

网关：`https://你的域名/ipfs/<CID>/…` 需要 nginx 反代到 `127.0.0.1:8080`；也可以只 pin 不开网关，让公共网关（ipfs.io、cloudflare-ipfs.com）拉取。
