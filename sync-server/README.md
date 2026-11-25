# 嘤阅同步服务（Docker）

给嘤阅 App 用的私有同步后端：**进度/书签/统计即时同步 + 备份上传下载 + WebDAV 兼容**，
自带一个 macOS / iOS 风格的网页面板（浅色深色自适应）。

## 起服务（四种方式，挑一个）

**A. 直接构建（代码在本地）**

```bash
cd sync-server
# 改 docker-compose.yml 里的 SYNC_TOKEN / SYNC_TOKENS
docker compose up -d --build
```

**B. 用 Docker Hub 镜像**（镜像由 GitHub Actions 构建，`sync-server/docker-compose.image.yml`）

```bash
docker compose -f docker-compose.image.yml up -d
```

镜像名：`<DOCKERHUB_USERNAME>/yingyue-sync:1.3`（在仓库 Secrets 配 `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` 后，
Actions 里的 `docker-sync` 会自动构建推送；GHCR 版本是 `ghcr.io/<owner>/yingyue-sync:1.3`）。

**C. 从 GitHub 仓库构建**（NAS 能访问 GitHub 时最省事，`sync-server/docker-compose.git.yml`）

```bash
docker compose -f docker-compose.git.yml up -d
```

**D. 不用 Docker**：`SYNC_TOKEN=test PORT=8090 python3 server.py`

改完令牌后打开 `http://<IP>:8090`。

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

## 外网访问（朋友/自己不在同一个网络）

两种方式，任选：

1. **端口映射 + 域名/DDNS**：路由器把 8090 映射出去，App 里「外网地址」填 `http://你的域名:8090`
   （建议再套一层 HTTPS，见下）。
2. **反代自动 HTTPS（推荐）**：用同目录的 `docker-compose.external.yml`，它带一个 Caddy，
   把 `SYNC_DOMAIN` 指向你的域名即可自动签证书：

```bash
SYNC_DOMAIN=sync.example.com docker compose -f docker-compose.external.yml up -d --build
# 之后 App 外网地址填 https://sync.example.com
```

App 端可以同时填「外网地址 + 内网地址」：每次同步先探测，哪个通就用哪个，在家走内网、出门走外网。

## 多人共用（朋友各用各的）

```yaml
environment:
  - SYNC_TOKENS=me:tokenA,friend:tokenB
```

每个令牌对应独立数据目录 `data/users/<名字>/`（状态、备份、WebDAV、章节都隔离）。

## 在线搜书 / 在线阅读（不依赖 App）

网页面板 →「在线搜书」→ 输入书名 → 点结果直接看目录、读正文或漫画。
服务端用**迷你书源引擎**在 Docker 里跑书源规则，不需要 App 打开。

支持的规则（覆盖内置书源和大多数 CSS/JSON 源）：

- 选择器：`tag`、`.class`、`#id`、`tag.class`、`tag.1`（第 N 个）、后代 `div.x ul li`
- 属性：`@text`、`@html`、`@href`、`@src`、`@title`、`@content`，支持嵌套 `dl.1@tag.dd`
- 兜底：`a || b`；正则：`##pattern##replacement`
- JSON 源：`$`、`$.a.b`、`$[*]`、`$.query.pages.*`
- 请求：searchUrl 的 `,{"method":"POST","body":"q={{key}}","headers":{...}}`，`{{page}}` 也支持；每源独立 Cookie，搜索→目录→正文共享

接口：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/search?key=` | 并发搜所有启用书源，按书名+作者去重 |
| GET | `/api/book?source=&url=` | 取目录 |
| GET | `/api/read?source=&url=` | 取正文（小说文本 / 漫画图片地址）|
| GET | `/api/img?u=&r=&token=` | 图片代理（带 Referer，绕过防盗链/CORS）|

**限制**：`@js:`、`@xpath:`、需要登录/加密的源跑不了（会明确返回空/提示），这些源仍要在 App 里用。

## 网页端直接看书 / 看漫画

- App 设置里打开「同步正文 / 图片」后，读过的章节会把正文（或漫画图片地址）传到服务器；
- 打开网页面板 →「书架」→ 点一本书 → 选章节，直接读；
- 漫画图片由服务器下载并缓存（带 Referer），网页里直接显示，不受站点防盗链影响；
- 网页里翻章会自动回写进度，App 下次启动拉取时会合并。

接口：`POST /api/chapters`（`{path,index,title,text|images,referer}`）、
`GET /api/chapters/list?path=`、`GET /api/chapters?path=&index=`。

> 说明：网页端既能读已同步的章节，也能用上面的「在线搜书」直接读（CSS/JSON 类源）。