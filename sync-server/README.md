# 嘤阅同步服务（Docker）

给嘤阅 App 用的私有同步后端：**进度/书签/统计即时同步 + 备份上传下载 + WebDAV 兼容**，
自带一个 macOS / iOS 风格的网页面板（浅色深色自适应）。

## 起服务

```bash
cd sync-server
# 改 docker-compose.yml 里的 SYNC_TOKEN
docker compose up -d --build
```

打开 `http://<服务器IP>:8090`，输入令牌即可看到：最近同步、最近阅读、备份、设备。

数据都在 `./data`：`state.json`（同步状态）、`backups/`（zip 备份）、`dav/`（WebDAV 文件）。

## App 里怎么配

设置 →「同步服务器」：

| 项 | 填什么 |
| --- | --- |
| 地址 | `http://<服务器IP>:8090` |
| 令牌 | 与 `SYNC_TOKEN` 一致 |
| 立即同步 | 手动推一次 + 拉一次 |

- 读一章 / 加书签 / 改进度后，App 会**防抖 3 秒自动推送**（失败静默、下次再推）
- App 启动时自动拉取最新记录并**按时间取新合并**，不会把新进度冲掉
- 「备份与恢复」里也可以把 WebDAV 地址填 `http://<IP>:8090/dav/`（用户名随便、密码=令牌），
  或用 REST：`POST /api/backups`（原始 zip）、`GET /api/backups/<name>`

## 接口

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/health` | 健康检查（不需要令牌） |
| GET | `/api/summary` | 面板数据：书籍数/书签数/设备/备份/最近阅读 |
| GET | `/api/state` | 完整同步状态（JSON） |
| POST | `/api/state` | 推送状态，按 path/lastReadAt、书签 id、统计取大合并 |
| GET | `/api/backups` | 备份列表 |
| POST | `/api/backups` | 上传 zip 备份（原始 body），自动保留最近 N 份 |
| GET | `/api/backups/<name>` | 下载备份 |
| DELETE | `/api/backups/<name>` | 删除备份 |
| * | `/dav/...` | WebDAV 子集：OPTIONS / PROPFIND / MKCOL / PUT / GET / DELETE |

鉴权：`Authorization: Bearer <SYNC_TOKEN>`、Basic（密码=令牌）、`X-Token` 或 `?token=`。

## 本地不用 Docker 也能跑

```bash
DATA_DIR=./data PORT=8090 SYNC_TOKEN=test python3 server.py
```

只需要 Python 3.8+，无第三方依赖。
