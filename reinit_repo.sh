#!/usr/bin/env bash
# =============================================================================
# reinit_repo.sh
#
# 完全重建本地 git 仓库并强制覆盖远端 GitHub + 可选 Gitee 的历史。
# 用于"切换仓库身份"的场景：丢掉旧历史，用当前代码作为唯一 commit (Init Commit)。
# 设置 GITEE_TOKEN 后自动同步代码 + tag + release（含附件）到 Gitee，保持两边一致。
#
# 使用：
#   ./reinit_repo.sh <repo>                     # 完整执行 (会要求确认)
#   ./reinit_repo.sh <repo> --dry-run           # 只探测环境，不执行破坏性操作
#   ./reinit_repo.sh <repo> --keep-tags         # 保留远端 tag (默认删除)
#   ./reinit_repo.sh <repo> --user <name>       # 覆盖 GitHub 用户名 (默认 qhgary)
#   ./reinit_repo.sh <repo> --branch <name>     # 覆盖分支名 (默认 main)
#   ./reinit_repo.sh <repo> --release-tag <tag>      # 发布 Release (与 title/notes 同用)
#   ./reinit_repo.sh <repo> --release-title <title>  # Release 标题
#   ./reinit_repo.sh <repo> --release-notes <file>   # Release 页面内容 (Markdown)
#   ./reinit_repo.sh <repo> --release-assets <p>     # 附件: 单文件或目录(直接子文件,非递归)
#   ./reinit_repo.sh <repo> --github-token <tok>   # GitHub PAT (CLI 参数, 优先级高于环境变量)
#
#   Gitee 同步 (可选): 设置 GITEE_TOKEN 后, 在 GitHub 完成后自动同步代码到 Gitee 同名仓库,
#   并用同样的 tag/标题/notes/附件发布 Gitee release (先建新->传附件->再删旧, 保证 latest 不中断)。
#   ./reinit_repo.sh <repo> --gitee-user <name>      # Gitee 用户名 (默认同 GitHub user)
#   ./reinit_repo.sh <repo> --gitee-repo <repo>      # Gitee 仓库名 (默认同 GitHub repo)
#   ./reinit_repo.sh <repo> --gitee-branch <name>    # Gitee 分支名 (默认同 GitHub 分支)
#   ./reinit_repo.sh <repo> --gitee-token <token>    # 或环境变量 GITEE_TOKEN
#   Gitee 附件上传走官方 gitee-release-cli 同款接口 POST /releases/{id}/attach_files (multipart)。
#
# Release 发布示例 (token 通过 CLI 或环境变量提供):
#   ./reinit_repo.sh zen_plugin_apps --github-token ghp_xxxx \
#       --release-tag v1.0.0 \
#       --release-title "禅中看缠 v1.0.0" \
#       --release-notes RELEASE.md \
#       --release-assets applications/dist/common
#   # 或用环境变量 (三选一, CLI 优先):
#   export GITHUB_TOKEN=ghp_xxxx        # classic PAT (repo scope)
#   # export GH_TOKEN=github_pat_xxxx   # fine-grained (该仓库 Contents: RW)
#   # export GH_PAT=ghp_xxxx            # 同上
#   ./reinit_repo.sh zen_plugin_apps \
#       --release-tag v1.0.0 \
#       --release-title "禅中看缠 v1.0.0" \
#       --release-notes RELEASE.md \
#       --release-assets applications/dist/common
#   # 同时同步到 Gitee:
#   export GITEE_TOKEN=ght_xxxx   # 或 --gitee-token ght_xxxx
#
# Token 与命令执行的说明:
#   - --github-token CLI 参数优先级最高 (高于环境变量)
#   - 未传 CLI 时, 三个环境变量任设其一即可, 按 GITHUB_TOKEN > GH_TOKEN > GH_PAT 探测
#   - PAT 与 fine-grained token 只是签发方式不同, API 调用命令完全一致 (无需区分)
#   - 没有任何 token: 有 release 参数时会交互询问 [c]跳过发布页继续 / [a]终止
#   ./reinit_repo.sh --help                     # 显示帮助
#
# 参数：
#   <repo>    必填，GitHub 仓库名（裸仓库名，不要带 user/ 前缀）
#
# 设计要点 (从第一次手工操作中沉淀的经验)：
#   1. SSH 443 端口必须显式 keepalive，否则 100MB+ pack 传输中连接会被中间链路 reset
#   2. core.gitProxy 必须显式清空 (SSH 直连不走 git:// 代理)
#   3. http.postBuffer / ssh.postBuffer 必须调到 1GB，默认 1MB 不够
#   4. 用 --force-with-lease (从 fetch origin main 拿 fresh sha) — 抗并发 push race
#      * 全新本地仓库 (远端 main 不存在) 时, 用 zero-sha 当 lease, Git 接受该 sha
#        表示 "接受任意旧值", 等价于 --force 但仍走 lease 校验路径
#      * 远端 main 已存在时, lease 必须匹配 — 如果推送过程中被别人改了, push 会
#        立刻拒绝 (不会传 167MB 到一半才发现 lock 错误)
#      * 失败时 push_with_retry 自动重新 fetch + 重试, 最多 5 次
#   5. git gc 把所有对象打成单 pack，传输更连续
#   6. 默认删除所有远端 tag (用户场景：彻底清空 GitHub 历史)
#
# 探测行为：
#   - SSH 私钥必须存在且可用 (代码推送的唯一通道, 与是否设置 token 无关;
#     缺失/不可用时脚本直接终止并给出设置指引, 不会退化成 token 推送)
#   - GitHub Token (环境变量, 三选一): GITHUB_TOKEN / GH_TOKEN / GH_PAT
#     * 无 release 参数: 可选 — 存在则迁移旧 release 元数据到新 commit
#     * 有 release 参数: 必需 — 创建 Release 页面/上传附件走 REST API, SSH 无法调用
#     * 类型: classic PAT (勾 repo scope) 或 fine-grained token (该仓库 Contents: RW) 均可
#       二者对 REST API 的调用方式完全相同 (Authorization: token <值>), 脚本不区分
#     * 注意: gh CLI 的登录态(keyring)不是环境变量, 不会被本脚本读取
#     * token 只用于 Release API (页面/附件) 与旧 release 迁移 — 绝不用于 git 推送
#   - Gitee Token (可选): GITEE_TOKEN (私人令牌, projects 写权限)
#     * 设置后自动在 GitHub 完成后同步代码 + tag + release (含附件) 到 Gitee
#     * API: access_token query param, 验证端点 https://gitee.com/api/v5/user?access_token=xxx
#   - .gitignore 必须存在
#   - .git 必须不存在 (用户已手工删除)
#   - 全部 AI IDE 隐藏目录 (.trae*/.catpaw*/.claude/.codex/.cursor/.opencode/.omo/.sisyphus 等 52 项) 检测到则确认后删除 (.github 仓库配置除外)
#
# 环境变量可覆盖默认值：
#   GIT_USER_NAME      qhgary
#   GIT_USER_EMAIL     qhgary@sina.com
#   GIT_COMMIT_MSG     "Init Commit"
#   VERIFY_TIMEOUT     300   # 远端验证最长等待秒数
# =============================================================================

set -euo pipefail

# =============================================================================
# 默认配置
# =============================================================================
GIT_REMOTE_USER="${GIT_REMOTE_USER:-qhgary}"
GIT_REMOTE_BRANCH="${GIT_REMOTE_BRANCH:-main}"
GIT_USER_NAME="${GIT_USER_NAME:-qhgary}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-qhgary@sina.com}"
GIT_COMMIT_MSG="${GIT_COMMIT_MSG:-Init Commit}"

DRY_RUN=false
KEEP_TAGS=false
AUTHOR_MISMATCH=false  # verify_author 标记位,用于 Summary 报告
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-300}"   # verification 阶段最长等待秒数 (默认 5 分钟)

# Release 发布参数 (--release-tag/--release-title/--release-notes 必须同给; --release-assets 可选)
RELEASE_TAG=""
RELEASE_TITLE=""
RELEASE_NOTES=""
RELEASE_ASSETS=""
RELEASE_ENABLED=false   # preflight 阶段决定 (PAT 校验通过才为 true)
RELEASE_ASSET_LIST=""   # preflight 生成的附件绝对路径清单文件

# GitHub Token (--github-token 或环境变量 GITHUB_TOKEN/GH_TOKEN/GH_PAT; CLI 优先)
GH_TOKEN_CLI=""            # --github-token 专用接收位 (解析后由 probe 合并)

# Gitee 同步参数 (可选; 设置了 GITEE_TOKEN 才启用 Gitee 阶段)
GITEE_REMOTE_USER=""
GITEE_REMOTE_REPO=""
GITEE_REMOTE_BRANCH=""
GITEE_TOKEN="${GITEE_TOKEN:-}"
GITEE_API_USER=""   # probe 阶段由 API 验证写入

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# 参数解析
# =============================================================================
usage() {
    sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

GIT_REMOTE_REPO=""
GH_TOKEN_CLI=""  # --github-token 专用接收位 (避免与 env GITHUB_TOKEN 混用)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true; shift ;;
        --keep-tags)  KEEP_TAGS=true; shift ;;
        --user)       GIT_REMOTE_USER="$2"; shift 2 ;;
        --branch)     GIT_REMOTE_BRANCH="$2"; shift 2 ;;
        --release-tag)    RELEASE_TAG="$2"; shift 2 ;;
        --release-title)  RELEASE_TITLE="$2"; shift 2 ;;
        --release-notes)  RELEASE_NOTES="$2"; shift 2 ;;
        --release-assets) RELEASE_ASSETS="$2"; shift 2 ;;
        --github-token)  GH_TOKEN_CLI="$2"; shift 2 ;;
        --gitee-user)     GITEE_REMOTE_USER="$2"; shift 2 ;;
        --gitee-repo)     GITEE_REMOTE_REPO="$2"; shift 2 ;;
        --gitee-branch)   GITEE_REMOTE_BRANCH="$2"; shift 2 ;;
        --gitee-token)    GITEE_TOKEN="$2"; shift 2 ;;
        --help|-h)    usage ;;
        --*)
            echo -e "${RED}[ERROR]${NC} Unknown flag: $1" >&2
            echo "Run '$0 --help' for usage" >&2
            exit 1
            ;;
        *)
            if [[ -z "$GIT_REMOTE_REPO" ]]; then
                GIT_REMOTE_REPO="$1"
                shift
            else
                echo -e "${RED}[ERROR]${NC} Unexpected extra positional arg: $1" >&2
                echo "Run '$0 --help' for usage" >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$GIT_REMOTE_REPO" ]]; then
    echo -e "${RED}[ERROR]${NC} Missing required argument: <repo>" >&2
    echo "Run '$0 --help' for usage" >&2
    exit 1
fi

# 仓库名只允许合法字符（防止 URL 注入）
if ! [[ "$GIT_REMOTE_REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo -e "${RED}[ERROR]${NC} Invalid repo name: '$GIT_REMOTE_REPO'" >&2
    echo "Allowed chars: letters, digits, '.', '_', '-'" >&2
    exit 1
fi

# Gitee 默认与 GitHub 同 user/repo/branch
[[ -z "$GITEE_REMOTE_USER" ]]   && GITEE_REMOTE_USER="$GIT_REMOTE_USER"
[[ -z "$GITEE_REMOTE_REPO" ]]   && GITEE_REMOTE_REPO="$GIT_REMOTE_REPO"
[[ -z "$GITEE_REMOTE_BRANCH" ]] && GITEE_REMOTE_BRANCH="$GIT_REMOTE_BRANCH"

# Release 参数: tag/title/notes 全有或全无 (无默认值); assets 可选
if [[ -n "$RELEASE_TAG$RELEASE_TITLE$RELEASE_NOTES$RELEASE_ASSETS" ]]; then
    if [[ -z "$RELEASE_TAG" || -z "$RELEASE_TITLE" || -z "$RELEASE_NOTES" ]]; then
        echo -e "${RED}[ERROR]${NC} --release-tag/--release-title/--release-notes must be used together (all or nothing)" >&2
        exit 1
    fi
    if ! git check-ref-format "refs/tags/$RELEASE_TAG" >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} Invalid release tag: '$RELEASE_TAG'" >&2
        exit 1
    fi
    if [[ ! -f "$RELEASE_NOTES" ]]; then
        echo -e "${RED}[ERROR]${NC} Release notes file not found: '$RELEASE_NOTES'" >&2
        exit 1
    fi
    if [[ -n "$RELEASE_ASSETS" && ! -e "$RELEASE_ASSETS" ]]; then
        echo -e "${RED}[ERROR]${NC} Release assets path not found: '$RELEASE_ASSETS'" >&2
        exit 1
    fi
fi

# =============================================================================
# 工具函数
# =============================================================================
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BLUE}=== $* ===${NC}"; }

# =============================================================================
# Release 预检: 在任何破坏性操作之前执行 (main 链第一步)
# 校验 release 参数/附件清单/PAT; 权限不足时交互 2 选 1:
#   [c] 继续执行 (本次跳过发布页)   [a] 立即终止
# 设置全局: RELEASE_ENABLED / AUTH_TOKEN / AUTH_USER / RELEASE_ASSET_LIST
# =============================================================================
preflight_release() {
    if [[ -z "$RELEASE_TAG" ]]; then
        RELEASE_ENABLED=false
        return 0   # 未设置 release 参数: 与旧版行为完全一致
    fi

    log_section "Release Preflight"

    # --- notes 文件非空校验 ---
    if [[ ! -s "$RELEASE_NOTES" ]]; then
        abort "Release notes file is empty or unreadable: $RELEASE_NOTES"
    fi
    log_ok "Release notes: $RELEASE_NOTES ($(wc -c < "$RELEASE_NOTES" | tr -d ' ') bytes)"

    # --- 附件清单: 单文件原样; 目录取直接子文件 (非递归, 跳过子目录) ---
    RELEASE_ASSET_LIST=""
    if [[ -n "$RELEASE_ASSETS" ]]; then
        local assets_tmp
        assets_tmp=$(mktemp -t zen_assets.XXXXXX.txt)
        if [[ -f "$RELEASE_ASSETS" ]]; then
            printf '%s\n' "$RELEASE_ASSETS" > "$assets_tmp"
        elif [[ -d "$RELEASE_ASSETS" ]]; then
            # .DS_Store 已在 .gitignore 中确认忽略, 同步跳过
            find "$RELEASE_ASSETS" -maxdepth 1 -type f \
                ! -name '.DS_Store' ! -name '.DS_Store?' | sort > "$assets_tmp"
        else
            abort "Release assets path not found: $RELEASE_ASSETS"
        fi
        local n_assets
        n_assets=$(wc -l < "$assets_tmp" | tr -d ' ')
        if [[ "$n_assets" -eq 0 ]]; then
            abort "No uploadable files found in: $RELEASE_ASSETS (direct files only, non-recursive)"
        fi
        # basename 去重 + GitHub 保留名检查
        if ! python3 - "$assets_tmp" <<'PY'
import os, sys
names = [os.path.basename(p.strip()) for p in open(sys.argv[1]) if p.strip()]
dup = sorted({x for x in names if names.count(x) > 1})
reserved = [n for n in names if n in ("Source code (zip)", "Source code (tar.gz)")]
if dup:
    print("Duplicate asset basenames: " + ", ".join(dup), file=sys.stderr)
    sys.exit(1)
if reserved:
    print("Reserved asset names not allowed: " + ", ".join(reserved), file=sys.stderr)
    sys.exit(1)
PY
        then
            abort "Asset list validation failed (see messages above)"
        fi
        RELEASE_ASSET_LIST="$assets_tmp"
        log_ok "Assets: $n_assets file(s) from $RELEASE_ASSETS"
    else
        log_info "Assets: none (release page with auto source archives only)"
    fi

    # --- PAT 校验: 创建 Release 页面/上传附件必须 token (SSH 无法调用 REST API) ---
    # 探测顺序: --github-token CLI (GH_TOKEN_CLI) > env GITHUB_TOKEN > GH_TOKEN > GH_PAT
    AUTH_TOKEN=""
    AUTH_USER=""
    local pat_val pat_var api_resp

    # helper: validate a token via GitHub API
    _validate_gh_token() {
        local source_label="$1" val="$2"
        log_info "$source_label set (len=${#val}), validating via API..."
        api_resp=$(run_with_timeout 8 curl -sS -H "Authorization: token $val" \
                          -H "Accept: application/vnd.github+json" \
                          https://api.github.com/user 2>/dev/null || echo "")
        if [[ -n "$api_resp" ]] && echo "$api_resp" | grep -q '"login"'; then
            AUTH_TOKEN="$val"
            AUTH_USER=$(echo "$api_resp" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' \
                        | head -1 | sed 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            log_ok "Token valid (source=$source_label, user=$AUTH_USER)"
            return 0
        else
            log_warn "$source_label API validation failed (expired/invalid/insufficient scope?)"
            return 1
        fi
    }

    # 优先 --github-token CLI 参数
    if [[ -n "$GH_TOKEN_CLI" ]]; then
        _validate_gh_token "--github-token" "$GH_TOKEN_CLI" || true
    else
        # fallback 到环境变量
        for pat_var in GITHUB_TOKEN GH_TOKEN GH_PAT; do
            pat_val="${!pat_var:-}"
            if [[ -n "$pat_val" ]]; then
                _validate_gh_token "$pat_var" "$pat_val" && break
            fi
        done
    fi

    # --- 探测 GitHub 远端仓库 (对齐 Gitee Probe 风格, 走 git ls-remote SSH) ---
    if [[ -n "$AUTH_TOKEN" ]]; then
        log_section "GitHub Probe"
        log_info "Probing GitHub remote: $GIT_REMOTE_USER/$GIT_REMOTE_REPO..."
        local gh_refs
        if gh_refs=$(GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15' \
                     git ls-remote "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" 2>&1); then
            local gh_main
            gh_main=$(echo "$gh_refs" | awk '$2 == "refs/heads/'"$GIT_REMOTE_BRANCH"'" {print $1}')
            if [[ -n "$gh_main" ]]; then
                log_ok "GitHub $GIT_REMOTE_BRANCH exists: ${gh_main:0:12}"
            else
                log_info "GitHub $GIT_REMOTE_BRANCH does not exist yet (will create)"
            fi
            local gh_tag_count
            gh_tag_count=$(echo "$gh_refs" | awk '$2 ~ /^refs\/tags\//' | wc -l | tr -d ' ')
            log_info "GitHub remote tags: $gh_tag_count"
        else
            log_warn "Could not reach GitHub remote (will attempt push anyway)."
            log_warn "  Ensure SSH key is registered for $GIT_REMOTE_USER and repo '${GIT_REMOTE_REPO}' exists."
        fi
    fi

    if [[ -z "$AUTH_TOKEN" ]]; then
        if [[ "$DRY_RUN" == true ]]; then
            log_warn "No valid PAT — dry-run: release page would be SKIPPED"
            RELEASE_ENABLED=false
            return 0
        fi
        echo ""
        echo -e "${RED}=== Release 页面无法创建 (缺少有效 token) ===${NC}"
        echo -e "  SSH key 只能推送代码/tag; 创建 Release 页面与上传附件必须用 token (REST API)"
        echo -e "  任一方式提供 token 即可:"
        echo -e "    CLI:    --github-token <token>"
        echo -e "    环境变量 (三选一):"
        echo -e "      export GITHUB_TOKEN=<classic PAT, 勾 repo scope>"
        echo -e "      export GH_TOKEN=<classic PAT 或 fine-grained token>"
        echo -e "      export GH_PAT=<classic PAT 或 fine-grained token>"
        echo -e "  (PAT 与 fine-grained token 的 API 调用方式相同, 用哪种都行)"
        echo -e "  可选操作:"
        echo -e "    [c] 继续执行 (本次跳过发布页, 之后可手动创建)"
        echo -e "    [a] 立即终止"
        local answer
        while true; do
            read -r -p "Continue without release page, or abort? [c/a]: " answer
            case "$answer" in
                c|C)
                    RELEASE_ENABLED=false
                    log_warn "Release page SKIPPED by user choice — will continue code push only"
                    return 0
                    ;;
                a|A)
                    abort "Aborted by user (release PAT missing)"
                    ;;
                *)
                    echo "  Please answer 'c' or 'a'."
                    ;;
            esac
        done
    fi

    RELEASE_ENABLED=true
    log_ok "Release enabled: tag=$RELEASE_TAG title='$RELEASE_TITLE'"
}

# 在任何破坏性操作之前, 显示完整路径和仓库信息让用户确认
confirm_target() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0   # dry-run 不需要确认
    fi

    local abs_path
    abs_path=$(pwd -P)

    echo ""
    echo -e "${YELLOW}=== Target Confirmation ===${NC}"
    echo -e "  ${BLUE}Local path:${NC}      $abs_path"
    echo -e "  ${BLUE}Remote target:${NC}   git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git"
    echo -e "  ${BLUE}Branch:${NC}          ${GIT_REMOTE_BRANCH}"
    echo -e "  ${BLUE}Commit message:${NC}  '${GIT_COMMIT_MSG}'"
    if [[ "$KEEP_TAGS" == false ]]; then
        echo -e "  ${YELLOW}Will DELETE all remote tags${NC}"
    else
        echo -e "  ${GREEN}Will KEEP all remote tags${NC}"
    fi
    echo ""
    echo -e "${RED}This will FORCE OVERWRITE the remote '$GIT_REMOTE_BRANCH' branch.${NC}"
    echo -e "${RED}All remote history will be replaced with a single '$GIT_COMMIT_MSG'.${NC}"
    echo ""

    local answer
    while true; do
        read -r -p "Type 'yes' to continue, anything else to abort: " answer
        case "$answer" in
            yes|y|YES|Y)
                echo -e "${GREEN}[OK]${NC} Confirmed"
                return 0
                ;;
            "")
                echo -e "${YELLOW}[WARN]${NC} Empty input. Please type 'yes' to continue."
                ;;
            *)
                echo -e "${RED}[ERROR]${NC} Aborted by user"
                return 1
                ;;
        esac
    done
}

dry_exec() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would run: $*"
    else
        "$@"
    fi
}

abort() {
    log_error "$*"
    exit 1
}

# 计时器
now() { date +%s; }
fmt_duration() {
    local s=$1
    if (( s >= 60 )); then
        printf "%dm%ds" $((s/60)) $((s%60))
    else
        printf "%ds" "$s"
    fi
}

# 覆盖式单行进度条
# progress_render <phase> <percent 0-100> <elapsed_hms> <status> [eta_hms]
#   elapsed_hms / eta_hms: 必须是 fmt_duration 格式化后的字符串 (如 "1m23s"), 不要传裸秒数
# 输出格式: \r\033[2K[phase] ████░░░░ 42% elapsed/eta | status
#   - \033[2K: 清整行 (兼容任何终端/日志查看工具)
#   - \r: 回行首
#   - percent: 唯一百分比，反映**真实上传内容的进度**（来自 git --progress 的 Writing objects 字节进度），不是时间进度
BAR_WIDTH=30
progress_render() {
    local phase="$1" percent="$2" elapsed="$3" status="$4" eta="${5:-}"
    (( percent > 99 )) && percent=99
    (( percent < 0 )) && percent=0
    local filled=$(( percent * BAR_WIDTH / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    if [[ -n "$eta" ]]; then
        printf "\033[2K\r${BLUE}[%s]${NC} ${GREEN}%s${NC} %3d%% ${YELLOW}elapsed=%s eta=%s${NC} | %s" \
            "$phase" "$bar" "$percent" "$elapsed" "$eta" "$status"
    else
        printf "\033[2K\r${BLUE}[%s]${NC} ${GREEN}%s${NC} %3d%% ${YELLOW}elapsed=%s${NC} | %s" \
            "$phase" "$bar" "$percent" "$elapsed" "$status"
    fi
}

# 进度条收尾（清整行 + 换行 + OK）
progress_finish() {
    local phase="$1" elapsed_hms="$2" status="$3"
    printf "\033[2K\r${GREEN}[%s done]${NC} %s                                          \n" \
        "$phase" "$elapsed_hms"
    log_ok "$status"
}

# 强制 timeout 包装 — 防止任何检测动作超过用户指定秒数
# fallback 链: timeout → gtimeout → perl alarm → 裸执行
run_with_timeout() {
    local t=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$t" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$t" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e '
            use POSIX ":sys_wait_h";
            my $t = shift @ARGV;
            my $pid = fork();
            if ($pid == 0) { exec @ARGV; exit 127; }
            eval {
                local $SIG{ALRM} = sub { kill "TERM", $pid; };
                alarm $t;
                waitpid $pid, 0;
                alarm 0;
            };
            exit ($@ ? 124 : $? >> 8);
        ' "$t" "$@"
    else
        "$@"
    fi
}

# =============================================================================
# 环境探测
# =============================================================================
probe_environment() {
    log_section "Environment Probe"

    # --- CWD 检查: 必须在 git 仓库目录下 (但 .git 已经不存在) ---
    if [[ ! -f .gitignore ]]; then
        abort ".gitignore not found in CWD ($(pwd)). Run this script from the repository root."
    fi
    log_ok ".gitignore present"

    if [[ -d .git ]]; then
        # .git 存在: 显示当前 git 信息并请求用户确认删除
        local current_remote current_branch
        current_remote=$(git -C . config --get remote.origin.url 2>/dev/null || echo "<no remote>")
        current_branch=$(git -C . symbolic-ref --short HEAD 2>/dev/null || echo "<detached>")
        local commit_count
        commit_count=$(git -C . rev-list --count HEAD 2>/dev/null || echo "?")

        echo ""
        echo -e "${YELLOW}=== Existing .git Detected ===${NC}"
        echo -e "  ${BLUE}Local path:${NC}        $(pwd -P)/.git"
        echo -e "  ${BLUE}Current remote:${NC}   $current_remote"
        echo -e "  ${BLUE}Current branch:${NC}   $current_branch"
        echo -e "  ${BLUE}Commit count:${NC}     $commit_count"
        echo ""
        echo -e "${YELLOW}This script will DELETE .git to start fresh.${NC}"
        echo -e "${RED}All local git history will be lost.${NC}"

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would prompt to delete .git, then continue"
        else
            local answer
            while true; do
                read -r -p "Type 'delete' to confirm removing .git, anything else to abort: " answer
                case "$answer" in
                    delete|Delete|DELETE)
                        rm -rf .git
                        log_ok ".git deleted"
                        break
                        ;;
                    "")
                        echo -e "${YELLOW}[WARN]${NC} Empty input. Please type 'delete' to continue."
                        ;;
                    *)
                        abort "Aborted by user. .git was NOT deleted."
                        ;;
                esac
            done
        fi
    else
        log_ok ".git absent (already clean)"
    fi

    # --- AI IDE 隐藏目录清理 ---
    # 各 AI IDE / AI 编程助手会在项目根目录留下配置/上下文/会话目录，
    # 本地 AI 上下文不应被推到 GitHub。存在才删除，不存在自动跳过。
    # 列表 = 本机已安装的全部 AI IDE（含各变体）+ 常见未安装 AI IDE（防御性覆盖），共 52 项：
    # （注意: .github 是 GitHub 仓库配置(CI/Release 模板)，属于应提交内容，刻意排除）
    #   TRAE 家族:              .trae .trae-cn .trae-aicc .marscode(前身)
    #   猫爪 CatPawAI(美团):    .catpaw .catpawai .sankuai(CatPawAI/MCopilot)
    #   Claude Code:            .claude
    #   OpenAI Codex:           .codex
    #   Cursor:                 .cursor
    #   Gemini CLI:             .gemini
    #   Google Antigravity:     .antigravity .antigravity-ide
    #   Cline / Roo Code:       .cline .roo
    #   腾讯 CodeBuddy:         .codebuddy .codebuddycn
    #   Charm Crush:            .crush
    #   opencode 生态:          .opencode .omo(插件) .sisyphus(会话续跑状态)
    #   JoyCode:                .joycode .joycoder .joycode-editor
    #   通义灵码:                .lingma
    #   Qoder:                  .qoder .qoder-cn .qoder-cli .qodersec
    #   WorkBuddy:              .workbuddy
    #   ZCode:                  .zcode
    #   QMind / OCat / Hermes:  .qmind .ocat .hermes
    #   通用 agent:             .agents .agent-browser
    #   其它已装 AI 工具:        .ai_completion .securecoder .cc-switch(Claude 供应商切换)
    #   本地模型运行时:           .ollama
    #   常见未安装 AI IDE:       .windsurf .continue .copilot .qwen .iflow .amazonq
    #                          .codeium .augment .specstory .goose .droid .plandex
    local AI_HIDDEN_DIRS=(
        .trae .trae-cn .trae-aicc .marscode
        .catpaw .catpawai .sankuai
        .claude .codex .cursor .gemini
        .antigravity .antigravity-ide
        .cline .roo
        .codebuddy .codebuddycn
        .crush
        .opencode .omo .sisyphus
        .joycode .joycoder .joycode-editor
        .lingma
        .qoder .qoder-cn .qoder-cli .qodersec
        .workbuddy
        .zcode
        .qmind .ocat .hermes
        .agents .agent-browser
        .ai_completion .securecoder .cc-switch
        .ollama
        .windsurf .continue .copilot .qwen .iflow .amazonq
        .codeium .augment .specstory .goose .droid .plandex
    )
    local ai_dirs_found=()
    local ai_dir
    for ai_dir in "${AI_HIDDEN_DIRS[@]}"; do
        if [[ -e "$ai_dir" ]]; then
            ai_dirs_found+=("$ai_dir")
        fi
    done
    if [[ ${#ai_dirs_found[@]} -eq 0 ]]; then
        log_ok "No AI IDE hidden directories found"
    else
        echo ""
        echo -e "${YELLOW}=== AI Hidden Directories Detected ===${NC}"
        for ai_dir in "${ai_dirs_found[@]}"; do
            echo -e "  ${BLUE}Found:${NC} $ai_dir ($(du -sh "$ai_dir" 2>/dev/null | awk '{print $1}'))"
        done
        echo -e "${YELLOW}This script will DELETE all directories listed above.${NC}"

        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Would prompt to delete: ${ai_dirs_found[*]}"
        else
            local ai_answer
            while true; do
                read -r -p "Type 'delete' to confirm removing AI directories, anything else to abort: " ai_answer
                case "$ai_answer" in
                    delete|Delete|DELETE)
                        rm -rf "${ai_dirs_found[@]}"
                        log_ok "AI hidden directories deleted: ${ai_dirs_found[*]}"
                        break
                        ;;
                    "")
                        echo -e "${YELLOW}[WARN]${NC} Empty input. Please type 'delete' to continue."
                        ;;
                    *)
                        abort "Aborted by user. AI directories were NOT deleted."
                        ;;
                esac
            done
        fi
    fi

    # --- SSH 私钥探测 ---
    local ssh_key=""
    local key_candidates=("$HOME/.ssh/id_rsa" "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa")
    for k in "${key_candidates[@]}"; do
        if [[ -f "$k" ]]; then
            ssh_key="$k"
            break
        fi
    done
    if [[ -z "$ssh_key" ]]; then
        echo ""
        echo -e "${RED}=== 未检测到 SSH 私钥, 无法上传代码 ===${NC}"
        echo -e "  已检查: ${key_candidates[*]}"
        echo -e "  请按以下步骤设置 (一次性):"
        echo -e "    1. 生成密钥:  ssh-keygen -t ed25519 -C \"${GIT_USER_EMAIL}\""
        echo -e "       (一路回车即可, 私钥保存在 ~/.ssh/id_ed25519)"
        echo -e "    2. 复制公钥:  cat ~/.ssh/id_ed25519.pub"
        echo -e "    3. 添加到 GitHub: 打开 https://github.com/settings/keys -> New SSH key"
       echo -e "       粘贴公钥内容并保存"
        echo -e "    4. 测试连接:  ssh -T -p 443 git@ssh.github.com"
        echo -e "       看到 \"Hi <用户名>! You've successfully authenticated...\" 即成功"
        echo -e "  设置完成后重新运行本脚本。"
        echo ""
        abort "SSH private key setup required (steps above). Code upload disabled."
    fi
    local perms
    perms=$(stat -f "%Lp" "$ssh_key" 2>/dev/null || stat -c "%a" "$ssh_key" 2>/dev/null)
    if [[ "$perms" != "600" && "$perms" != "400" ]]; then
        log_warn "SSH key $ssh_key has permissions $perms (expected 600 or 400). Fixing..."
        dry_exec chmod 600 "$ssh_key"
    fi
    log_ok "SSH private key: $ssh_key (perms $perms)"

    # --- SSH config: github.com 必须映射到 ssh.github.com:443 ---
    if [[ -f "$HOME/.ssh/config" ]]; then
        # 使用 awk 解析 Host 块，检查 github.com 块内是否包含 HostName ssh.github.com
        local github_block
        github_block=$(awk '
            /^[Hh]ost[[:space:]]/ { in_host=1; host_match=($2 == "github.com"); block="" }
            in_host { block = block "\n" $0 }
            in_host && /^$/ { in_host=0 }
            END { if (host_match) print block }
        ' "$HOME/.ssh/config")
        if [[ -n "$github_block" ]] && echo "$github_block" | grep -q "ssh.github.com"; then
            log_ok ".ssh/config has github.com -> ssh.github.com (443) mapping"
        else
            log_warn ".ssh/config missing github.com -> ssh.github.com:443 mapping. Push may fail."
            log_warn "  Add to ~/.ssh/config:"
            log_warn "    Host github.com"
            log_warn "      HostName ssh.github.com"
            log_warn "      Port 443"
            log_warn "      User git"
            log_warn "      IdentityFile $ssh_key"
        fi
    else
        log_warn "$HOME/.ssh/config not found. Will use URL form: ssh://git@ssh.github.com:443/<user>/<repo>.git"
    fi

    # --- gh CLI 探测 ---
    local gh_path=""
    if command -v gh >/dev/null 2>&1; then
        gh_path=$(command -v gh)
        log_ok "gh CLI: $gh_path ($(gh --version | head -1))"
    else
        log_warn "gh CLI not found. Will fall back to pure git for tag deletion."
        log_warn "  Install: brew install gh"
    fi

    # --- PAT (Personal Access Token) 探测 + API 验证 ---
# 探测顺序: --github-token (GH_TOKEN_CLI) > env GITHUB_TOKEN > GH_TOKEN > GH_PAT
# CLI 传入的 token 优先级最高, 同样走 API 验证
# 一旦发现 token，立刻通过 REST API 验证是否有效 + 拿到用户名
# (release 预检已验证过时直接复用, 不重复请求 API)
    if [[ -n "${AUTH_TOKEN:-}" ]]; then
        log_ok "Token already validated in release preflight (user=${AUTH_USER:-?})"
    else
    AUTH_PAT=""
    AUTH_PAT_USER=""
    probe_gh_token() {
        local source_label="$1" val="$2"
        log_info "$source_label set (len=${#val}), validating via API..."
        local api_resp
        api_resp=$(run_with_timeout 8 curl -sS -H "Authorization: token $val" \
                                  -H "Accept: application/vnd.github+json" \
                                  https://api.github.com/user 2>/dev/null || echo "")
        if [[ -n "$api_resp" ]] && echo "$api_resp" | grep -q '"login"'; then
            AUTH_PAT="$val"
            AUTH_PAT_USER=$(echo "$api_resp" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' \
                            | head -1 | sed 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            log_ok "Token valid — source=$source_label, user=$AUTH_PAT_USER"
            return 0
        else
            log_warn "$source_label API validation failed (expired/invalid)"
            return 1
        fi
    }
    # 优先用 --github-token CLI
    if [[ -n "$GH_TOKEN_CLI" ]]; then
        probe_gh_token "--github-token" "$GH_TOKEN_CLI" || true
    else
        # fallback 到环境变量
        for var in GITHUB_TOKEN GH_TOKEN GH_PAT; do
            local val="${!var:-}"
            if [[ -n "$val" ]]; then
                probe_gh_token "$var" "$val" && break
            fi
        done
    fi
    if [[ -z "$AUTH_PAT" ]]; then
        log_info "No valid GitHub PAT — code/tag push via SSH only; release page disabled."
    fi

    # 把 PAT 写到全局（供后续 release 重建使用）
    AUTH_TOKEN="$AUTH_PAT"
    AUTH_USER="$AUTH_PAT_USER"
    fi

    # --- GitHub 远端认证探测 ---
    # 注意：GitHub SSH 成功认证后返回 exit=1 (拒绝 shell 但认证 OK)，所以不能用 exit code 判断
    log_info "Probing GitHub authentication..."
    local ssh_probe_output
    ssh_probe_output=$(ssh -T -p 443 -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
                              -o BatchMode=yes git@ssh.github.com 2>&1 || true)
    if echo "$ssh_probe_output" | grep -q "successfully authenticated"; then
        local gh_user
        gh_user=$(echo "$ssh_probe_output" | grep -oE "Hi [^!]+!" | sed 's/Hi //; s/!$//')
        log_ok "GitHub SSH auth: OK (user=${gh_user:-$GIT_REMOTE_USER})"
    else
        echo ""
        echo -e "${RED}=== GitHub SSH 认证失败, 无法上传代码 ===${NC}"
        echo -e "  私钥文件存在, 但 GitHub 拒绝了认证。常见原因与处理:"
        echo -e "    1. 公钥未添加到 GitHub 账号"
        echo -e "       -> 打开 https://github.com/settings/keys 确认公钥已添加"
        echo -e "    2. 本机使用的私钥与 GitHub 上登记的公钥不配对"
        echo -e "       -> 用 ssh-keygen -y -f <私钥> 对比公钥指纹"
        echo -e "    3. 防火墙阻断 22 端口 (本脚本默认走 ssh.github.com:443)"
        echo -e "       -> 确认 ~/.ssh/config 含 github.com -> ssh.github.com:443 映射"
        echo -e "  设置/修正后用以下命令自测, 看到 successfully authenticated 即成功:"
        echo -e "    ssh -T -p 443 git@ssh.github.com"
        echo -e "  注意: 设置 GITHUB_TOKEN 等环境变量无助于代码推送, 推送只走 SSH。"
        echo ""
        abort "GitHub SSH auth failed (see troubleshooting above). Code upload disabled."
    fi

    # --- Gitee 探测 (可选, 设置了 GITEE_TOKEN 才启用) ---
    if [[ -n "${GITEE_TOKEN:-}" ]]; then
        log_section "Gitee Probe"
        log_info "GITEE_TOKEN set (length=${#GITEE_TOKEN}), validating via API..."
        local gitee_user_json
        gitee_user_json=$(run_with_timeout 8 curl -sS "https://gitee.com/api/v5/user?access_token=${GITEE_TOKEN}" 2>/dev/null || echo "")
        if [[ -n "$gitee_user_json" ]] && echo "$gitee_user_json" | grep -q '"login"'; then
            GITEE_API_USER=$(echo "$gitee_user_json" | grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]+"' \
                             | head -1 | sed 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            log_ok "Gitee token valid (user=$GITEE_API_USER)"
        else
            log_error "GITEE_TOKEN set but API validation failed (expired/invalid/insufficient scope?)"
            abort "Gitee token validation failed — fix GITEE_TOKEN or unset it to skip Gitee sync."
        fi

        # 探测 Gitee 远端仓库
        local gitee_remote_url="https://${GITEE_REMOTE_USER}:${GITEE_TOKEN}@gitee.com/${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}.git"
        log_info "Probing Gitee remote: $GITEE_REMOTE_USER/$GITEE_REMOTE_REPO..."
        local gitee_refs
        if gitee_refs=$(GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15' \
                        git ls-remote "$gitee_remote_url" 2>&1); then
            local gitee_main
            gitee_main=$(echo "$gitee_refs" | awk '$2 == "refs/heads/'"$GITEE_REMOTE_BRANCH"'" {print $1}')
            if [[ -n "$gitee_main" ]]; then
                log_ok "Gitee $GITEE_REMOTE_BRANCH exists: ${gitee_main:0:12}"
            else
                log_info "Gitee $GITEE_REMOTE_BRANCH does not exist yet (will create)"
            fi
            local gitee_tag_count
            gitee_tag_count=$(echo "$gitee_refs" | awk '$2 ~ /^refs\/tags\//' | wc -l | tr -d ' ')
            log_info "Gitee remote tags: $gitee_tag_count"
        else
            log_warn "Could not reach Gitee remote (will attempt push anyway)."
            log_warn "  Ensure repo '${GITEE_REMOTE_REPO}' exists on Gitee and token has projects write scope."
        fi
    else
        log_info "GITEE_TOKEN not set — Gitee sync disabled."
    fi

    # --- 远端仓库探测 ---
    log_info "Probing remote: $GIT_REMOTE_USER/$GIT_REMOTE_REPO..."
    local remote_refs
    if remote_refs=$(GIT_SSH_COMMAND='ssh -p 443 -o StrictHostKeyChecking=no -o ConnectTimeout=15' \
                     git ls-remote "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" 2>&1); then
        local current_main
        current_main=$(echo "$remote_refs" | awk '$2 == "refs/heads/'"$GIT_REMOTE_BRANCH"'" {print $1}')
        if [[ -n "$current_main" ]]; then
            log_ok "Remote $GIT_REMOTE_BRANCH exists: ${current_main:0:12}"
            local remote_tags
            remote_tags=$(echo "$remote_refs" | awk '$2 ~ /^refs\/tags\// {print $2}')
            local tag_count
            tag_count=$(echo "$remote_tags" | grep -c . || true)
            log_info "Remote tags: $tag_count"
            if [[ -n "$remote_tags" && "$KEEP_TAGS" == false ]]; then
                log_warn "Script will DELETE all remote tags after force push"
                echo "$remote_tags" | sed 's/^/    /'
            fi
        else
            log_info "Remote $GIT_REMOTE_BRANCH does not exist (fresh repo)"
        fi
    else
        abort "Failed to reach remote repo. Check network/auth."
    fi

    # --- git 命令探测 ---
    if ! command -v git >/dev/null 2>&1; then
        abort "git command not found"
    fi
    log_ok "git: $(git --version)"

    log_section "Environment Probe Complete"
}

# =============================================================================
# 执行
# =============================================================================
execute() {
    log_section "Execution"

    # --- git init ---
    log_info "Initializing fresh repo on branch $GIT_REMOTE_BRANCH..."
    dry_exec git init -b "$GIT_REMOTE_BRANCH"

    # --- 配置 git local (不影响全局 config, 必须 init 之后才能用 --local) ---
    log_info "Configuring git local settings..."
    dry_exec git config --local user.name "$GIT_USER_NAME"
    dry_exec git config --local user.email "$GIT_USER_EMAIL"
    dry_exec git config --local core.gitProxy ""
    dry_exec git config --local http.postBuffer 1048576000
    dry_exec git config --local ssh.postBuffer 1048576000
    log_ok "Local git configured"

    # --- 添加远端 (使用 .ssh/config 友好的 URL — 让 SSH config keepalive 生效) ---
    log_info "Adding remote origin..."
    dry_exec git remote add origin "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git"

    # --- stage 所有文件 ---
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: git add -A (then commit, gc, push, delete-tags)"
        log_info "[DRY-RUN] Skipping all destructive steps"
        return
    fi

    log_info "Staging all files (respecting .gitignore)..."
    git add -A

    local staged_count
    staged_count=$(git diff --cached --numstat | wc -l | tr -d ' ')
    log_ok "Staged $staged_count files"

    if [[ "$staged_count" == "0" ]]; then
        abort "Nothing to commit. Working tree is empty."
    fi

    # --- commit ---
    # 防御性清理: 防止 shell 环境里的 GIT_AUTHOR_* / GIT_COMMITTER_* 变量覆盖 local config
    # 某些 AI 工具会在 shell 注入这些环境变量,导致 commit author 变成 AI 而不是 qhgary
    unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
    unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

    # 显式覆盖 committer 也用 qhgary (不只是 author)。有些 git 操作只用 committer
    git config --local user.name "$GIT_USER_NAME"
    git config --local user.email "$GIT_USER_EMAIL"

    # 清理 commit message 里可能残留的 Co-authored-by: trailers
    # 默认 commit message 是 "Init Commit" — 不含 trailers, 但保留防御性逻辑
    local clean_msg="$GIT_COMMIT_MSG"
    if [[ "$clean_msg" == *"Co-authored-by:"* ]]; then
        log_warn "Stripping Co-authored-by trailer from commit message"
        clean_msg=$(echo "$clean_msg" | grep -v "^Co-authored-by:")
    fi

    log_info "Creating commit: '$clean_msg'"
    log_info "  Author:     $GIT_USER_NAME <$GIT_USER_EMAIL>"
    log_info "  Committer:  $GIT_USER_NAME <$GIT_USER_EMAIL> (forced via local config)"
    git commit -m "$clean_msg"

    # 立即清理任何 unreachable 对象(防止 AI commit 的残留对象进入 pack)
    # 使用 --prune=now 立即清理 (默认是 2 weeks ago)
    log_info "Running git gc --prune=now..."
    git gc --prune=now

    # --- force push (带 retry 抗 race condition) ---
    log_info "Force pushing to origin/$GIT_REMOTE_BRANCH (with auto-retry on lock conflicts)..."
    if ! push_with_retry; then
        log_error "Aborting: cannot proceed without a successful push (release 创建会用本地 HEAD sha, 远端没收到 -> GitHub 报 Validation Failed)."
        return 1
    fi

    # --- 删除所有远端 tag ---
    if [[ "$KEEP_TAGS" == false ]]; then
        delete_remote_tags
    fi

    # --- GitHub Releases: 设置了 release 参数 -> 创建全新发布(含附件);
    #     未设置 -> 沿用旧行为: 把旧 release 元数据迁移到新 commit ---
    if [[ "$RELEASE_ENABLED" == true ]]; then
        create_release_with_assets
    elif [[ -n "${AUTH_TOKEN:-}" ]]; then
        rebuild_releases
    else
        log_warn "No valid token — skipping GitHub Releases rebuild."
        log_warn "  To enable: export GITHUB_TOKEN (classic PAT w/ repo scope, or fine-grained w/ Contents:RW)."
        log_warn "  Releases at https://github.com/$GIT_REMOTE_USER/$GIT_REMOTE_REPO/releases will keep pointing to OLD commits."
    fi

    # --- Gitee 阶段: 同步代码 + 同版本 release (设置了 GITEE_TOKEN 才启用) ---
    if [[ -n "${GITEE_TOKEN:-}" ]]; then
        if ! push_to_gitee; then
            log_error "Gitee phase: code push failed."
            return 1
        fi
        if [[ -n "$RELEASE_TAG" ]]; then
            if ! publish_gitee_release; then
                log_error "Gitee phase: release publish failed (release may still be public)."
                return 1
            fi
        fi
    else
        log_info "GITEE_TOKEN not set — skipping Gitee sync (push + release)."
    fi

    log_section "Execution Complete"
}

# 后台执行 push，覆盖式单行进度条 + 真实百分比从 git --progress stderr 解析
# 通过 fetch_remote_main_sha 拿 fresh sha 给 --force-with-lease 抗并发 push race
push_with_progress() {
    local logfile
    logfile=$(mktemp -t zen_push.XXXXXX.log)

    local start_ts
    start_ts=$(now)

    # 关键: push 之前 fetch origin main 拿 fresh sha, 用 --force-with-lease 抗 race
    # 如果远端 main 已经被别人改了, lease 会立即拒绝, 不会传 167MiB 到一半才发现
    local lease_sha
    lease_sha=$(fetch_remote_main_sha)
    if [[ -z "$lease_sha" ]]; then
        # 远端 main 不存在 (空仓库), 用 zero sha 让 lease 跳过 old-oid 校验
        lease_sha="0000000000000000000000000000000000000000"
    fi

(date '+%H:%M:%S'
     echo "[START] push --progress --force-with-lease=refs/heads/$GIT_REMOTE_BRANCH:$lease_sha -u origin $GIT_REMOTE_BRANCH"
     GIT_SSH_COMMAND='ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=30 -o TCPKeepAlive=yes -o IPQoS=throughput' \
        git push --progress --force-with-lease="refs/heads/$GIT_REMOTE_BRANCH:$lease_sha" \
        -u origin "$GIT_REMOTE_BRANCH" 2>&1
     echo "[END] exit_code=$?"
     date '+%H:%M:%S') > "$logfile" 2>&1 &

    local pid=$!
    disown

    # 主循环渲染覆盖式单行进度条。
    # 关键设计: 进度状态 (percent/phase/rate/done_bytes) 默认值粘性 — 上一帧拿到的值保留到下一帧,
    # 只有 tail_line 里明确解析到新进度才覆盖。这样:
    #   - server-side processing 期间客户端拿不到新行, 进度条**停在最后一帧**而不是跳回 0%
    #   - push 完成后 server 仍占着连接, 最后一次 sleep 5s 渲染时也保持完成态 (100% writing)
    local percent=0
    local phase="starting"
    local rate_bps=0
    local done_bytes=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        local elapsed=$(( $(now) - start_ts ))
        local tail_line
        tail_line=$(LC_ALL=C tail -c 4096 "$logfile" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -1)

        if [[ -n "$tail_line" ]]; then
            local pct_str
            pct_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9]+%' | tail -1 | tr -d '%')
            if [[ -n "$pct_str" ]]; then
                percent="$pct_str"
            fi

            case "$tail_line" in
                *"Enumerating objects"*)  phase="enumerating" ;;
                *"Counting objects"*)     phase="counting"    ;;
                *"Delta compression"*)     phase="compressing" ;;
                *"Compressing objects"*)   phase="compressing" ;;
                *"Writing objects"*)
                    phase="writing"
                    local rate_str
                    rate_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9.]+[[:space:]]*(KiB|MiB|GiB)/s' | tail -1)
                    if [[ -n "$rate_str" ]]; then
                        local num unit
                        num=$(echo "$rate_str" | awk '{print $1}')
                        unit=$(echo "$rate_str" | awk '{print $2}')
                        case "$unit" in
                            KiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024}') ;;
                            MiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}') ;;
                            GiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024*1024}') ;;
                        esac
                    fi
                    local done_str
                    done_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9.]+[[:space:]]*(KiB|MiB|GiB)([[:space:]]*\||$)' | tail -1 | awk '{print $1, $2}')
                    if [[ -n "$done_str" ]]; then
                        local dnum dunit
                        dnum=$(echo "$done_str" | awk '{print $1}')
                        dunit=$(echo "$done_str" | awk '{print $2}' | tr -d '|')
                        case "$dunit" in
                            KiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024}') ;;
                            MiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024*1024}') ;;
                            GiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024*1024*1024}') ;;
                        esac
                    fi
                    ;;
                *) phase="working" ;;
            esac
        fi

        (( percent > 99 )) && percent=99
        (( percent < 1 )) && percent=0

        local eta_hms="?"
        if (( percent > 0 && percent < 100 && rate_bps > 0 && done_bytes > 0 )); then
            local remaining_bytes eta_sec
            remaining_bytes=$(awk -v d="$done_bytes" -v p="$percent" 'BEGIN{printf "%d", d*(100-p)/p}')
            eta_sec=$(awk -v r="$remaining_bytes" -v bps="$rate_bps" 'BEGIN{printf "%d", r/bps}')
            if (( eta_sec > 0 )); then
                eta_hms=$(fmt_duration "$eta_sec")
            fi
        fi

        local rate_human="?"
        if (( rate_bps > 0 )); then
            rate_human=$(awk -v b="$rate_bps" 'BEGIN{
                if (b >= 1048576) printf "%.1f MiB/s", b/1048576
                else if (b >= 1024) printf "%.0f KiB/s", b/1024
                else printf "%d B/s", b
            }')
        fi
        local elapsed_hms
        elapsed_hms=$(fmt_duration "$elapsed")
        progress_render "push" "$percent" "$elapsed_hms" "$rate_human" "$eta_hms"
    done

    local end_ts
    end_ts=$(now)
    local total_elapsed=$(( end_ts - start_ts ))

    wait "$pid" 2>/dev/null || true
    local exit_code
    exit_code=$(grep "^\[END\]" "$logfile" | awk -F= '{print $2}' | tr -d ' ')
    cat "$logfile"
    rm -f "$logfile"

    if [[ "$exit_code" != "0" ]]; then
        printf "\n"
        log_warn "git push failed (exit=$exit_code, took $(fmt_duration $total_elapsed)). See log above."
        return 1
    fi
    local total_hms
    total_hms=$(fmt_duration "$total_elapsed")
    progress_finish "push" "$total_hms" "Force push succeeded in $total_hms"
}

# 从 GitHub 拉一次远端 main 的当前 sha, 供 --force-with-lease 当 lease
# 返回值是 40 字符 hex, 失败/不存在返回空字符串
fetch_remote_main_sha() {
    GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10' \
        git ls-remote "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" \
        "refs/heads/$GIT_REMOTE_BRANCH" 2>/dev/null \
        | awk '{print $1}' | head -1
}

# push_with_progress 的 retry wrapper
# 抗并发 push race condition: 远端 main 在 push 期间被别人改了会导致 lease 不匹配
# 检测到 "cannot lock ref" / "stale info" 时, 重新 fetch 后再 push, 最多 5 次
PUSH_MAX_RETRIES="${PUSH_MAX_RETRIES:-5}"
PUSH_RETRY_DELAY="${PUSH_RETRY_DELAY:-15}"   # 秒, 给"抢占者"完成 + GitHub settle 时间
push_with_retry() {
    local attempt=1
    while (( attempt <= PUSH_MAX_RETRIES )); do
        local pre_sha
        pre_sha=$(fetch_remote_main_sha)
        log_info "Push attempt $attempt/$PUSH_MAX_RETRIES (lease=$GIT_REMOTE_BRANCH:${pre_sha:-<empty>})"

        if push_with_progress; then
            return 0
        fi

        # push 失败 — 区分 race condition 和真错
        local post_sha
        post_sha=$(fetch_remote_main_sha)
        local local_sha
        local_sha=$(git rev-parse HEAD)

        if [[ -z "$post_sha" ]]; then
            # 远端 main 没了 (有人删了 main) — 下次重试会用 zero-sha lease
            log_warn "Remote main is GONE. Next retry will recreate."
        elif [[ "$post_sha" == "$local_sha" ]]; then
            # 远端已经是我们要的 sha 了 — push "失败" 但其实成功了
            log_ok "Remote main already at $local_sha (race resolved itself)"
            return 0
        elif [[ "$post_sha" != "$pre_sha" ]]; then
            # 远端 main 变了 — 是 race condition, 重试
            log_warn "Remote main changed during push: ${pre_sha:-<empty>} -> $post_sha (race condition detected)"
        else
            # 远端没变, 但 push 还是失败 — 是真错 (网络/认证/对象缺失), 不要 retry
            log_error "Push failed but remote main unchanged ($post_sha). This is a real error, not a race."
            log_error "Check: network connectivity, SSH key validity, or git object corruption."
            return 1
        fi

        if (( attempt < PUSH_MAX_RETRIES )); then
            log_info "Retrying in ${PUSH_RETRY_DELAY}s..."
            sleep "$PUSH_RETRY_DELAY"
        fi
        ((attempt++))
    done

    log_error "Push failed after $PUSH_MAX_RETRIES attempts. Last remote main: ${post_sha:-<empty>}"
    log_error "Manual fix: delete remote main branch on https://github.com/$GIT_REMOTE_USER/$GIT_REMOTE_REPO/settings/branches"
    log_error "  Then re-run this script. --force-with-lease will recreate main from scratch."
    return 1
}

delete_remote_tags() {
    log_info "Deleting all remote tags..."
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would run: git push --delete origin <each-tag>"
        return
    fi

    local remote_tags
    remote_tags=$(GIT_SSH_COMMAND='ssh -p 443 -o StrictHostKeyChecking=no' \
                  git ls-remote --tags "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" 2>/dev/null \
                  | awk '{print $2}' | sed 's|refs/tags/||' | sort -u)

    if [[ -z "$remote_tags" ]]; then
        log_ok "No remote tags to delete"
        return
    fi

    while IFS= read -r tag; do
        if [[ -z "$tag" ]]; then continue; fi
        log_info "  Deleting tag: $tag"
        GIT_SSH_COMMAND='ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=30 -o TCPKeepAlive=yes' \
            git push --delete origin "$tag" 2>&1 | sed 's/^/    /'
    done <<< "$remote_tags"
    log_ok "All remote tags deleted"
}

# Gitee 专用的 push 进度函数 (HTTPS + token, GitHub SSH push_with_progress 的镜像版)
# 参数: $1 = gitee remote URL (https://user:token@gitee.com/...)
gitee_push_with_progress() {
    local push_url="$1"
    local logfile
    logfile=$(mktemp -t zen_gitee_push.XXXXXX.log)

    local start_ts
    start_ts=$(now)

    # Git 不允许 --all/--branches 与 --tags 同用, 拆成两次 push
    # (与 GitHub SSH push_with_progress 的镜像功能一致, 覆盖式进度条样式不变)
    (date '+%H:%M:%S'
     echo "[START] push --progress --force --all -u $push_url"
     git push --progress --force --all "$push_url" 2>&1
     echo "[MID] exit_code=$?"
     echo "[START] push --progress --force --tags -u $push_url"
     git push --progress --force --tags "$push_url" 2>&1
     echo "[END] exit_code=$?"
     date '+%H:%M:%S') > "$logfile" 2>&1 &

    local pid=$!
    disown

    # 主循环渲染覆盖式单行进度条, 与 push_with_progress 同构:
    # 进度状态粘性保留 (见 push_with_progress 注释), server-side processing 期间停在最后一帧.
    local percent=0
    local phase="starting"
    local rate_bps=0
    local done_bytes=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        local elapsed=$(( $(now) - start_ts ))
        local tail_line
        tail_line=$(LC_ALL=C tail -c 4096 "$logfile" 2>/dev/null | tr '\r' '\n' | grep -v '^$' | tail -1)

        if [[ -n "$tail_line" ]]; then
            local pct_str
            pct_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9]+%' | tail -1 | tr -d '%')
            if [[ -n "$pct_str" ]]; then
                percent="$pct_str"
            fi

            case "$tail_line" in
                *"Enumerating objects"*)  phase="enumerating" ;;
                *"Counting objects"*)     phase="counting"    ;;
                *"Delta compression"*)     phase="compressing" ;;
                *"Compressing objects"*)   phase="compressing" ;;
                *"Writing objects"*)
                    phase="writing"
                    local rate_str
                    rate_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9.]+[[:space:]]*(KiB|MiB|GiB)/s' | tail -1)
                    if [[ -n "$rate_str" ]]; then
                        local num unit
                        num=$(echo "$rate_str" | awk '{print $1}')
                        unit=$(echo "$rate_str" | awk '{print $2}')
                        case "$unit" in
                            KiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024}') ;;
                            MiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024}') ;;
                            GiB/s) rate_bps=$(awk -v n="$num" 'BEGIN{printf "%d", n*1024*1024*1024}') ;;
                        esac
                    fi
                    local done_str
                    done_str=$(echo "$tail_line" | LC_ALL=C grep -oE '[0-9.]+[[:space:]]*(KiB|MiB|GiB)([[:space:]]*\||$)' | tail -1 | awk '{print $1, $2}')
                    if [[ -n "$done_str" ]]; then
                        local dnum dunit
                        dnum=$(echo "$done_str" | awk '{print $1}')
                        dunit=$(echo "$done_str" | awk '{print $2}' | tr -d '|')
                        case "$dunit" in
                            KiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024}') ;;
                            MiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024*1024}') ;;
                            GiB) done_bytes=$(awk -v n="$dnum" 'BEGIN{printf "%d", n*1024*1024*1024}') ;;
                        esac
                    fi
                    ;;
                *) phase="working" ;;
            esac
        fi

        (( percent > 99 )) && percent=99
        (( percent < 1 )) && percent=0

        local eta_hms="?"
        if (( percent > 0 && percent < 100 && rate_bps > 0 && done_bytes > 0 )); then
            local remaining_bytes eta_sec
            remaining_bytes=$(awk -v d="$done_bytes" -v p="$percent" 'BEGIN{printf "%d", d*(100-p)/p}')
            eta_sec=$(awk -v r="$remaining_bytes" -v bps="$rate_bps" 'BEGIN{printf "%d", r/bps}')
            if (( eta_sec > 0 )); then
                eta_hms=$(fmt_duration "$eta_sec")
            fi
        fi

        local rate_human="?"
        if (( rate_bps > 0 )); then
            rate_human=$(awk -v b="$rate_bps" 'BEGIN{
                if (b >= 1048576) printf "%.1f MiB/s", b/1048576
                else if (b >= 1024) printf "%.0f KiB/s", b/1024
                else printf "%d B/s", b
            }')
        fi
        local elapsed_hms
        elapsed_hms=$(fmt_duration "$elapsed")
        progress_render "gitee-push" "$percent" "$elapsed_hms" "$rate_human" "$eta_hms"
    done

    wait "$pid" 2>/dev/null || true
    local exit_code
    exit_code=$(grep "^\[END\]" "$logfile" | awk -F= '{print $2}' | tr -d ' ')
    cat "$logfile"
    rm -f "$logfile"

    if [[ "$exit_code" != "0" ]]; then
        printf "\n"
        log_warn "Gitee push failed (exit=$exit_code). See log above."
        return 1
    fi
    progress_finish "gitee-push" "$(fmt_duration $(( $(now) - start_ts )))" "Gitee force push OK"
}

# =============================================================================
# 创建全新 Release (参数: --release-tag/--release-title/--release-notes[/--release-assets])
# 流程: 删所有旧 release + 同名 tag -> 创建 draft (tag 由 API 自动建在当前 HEAD 上)
#       -> 逐附件上传 (重试+校验) -> PATCH 发布
# 任一步失败: 报错退出, release 保持 draft 状态 (不会公开残缺页面)
# 前置: AUTH_TOKEN 有效 (preflight_release 已校验)
# =============================================================================
create_release_with_assets() {
    log_section "Create GitHub Release"
    local api_root="https://api.github.com"
    local repo="$GIT_REMOTE_USER/$GIT_REMOTE_REPO"
    local auth_header=(-H "Authorization: token $AUTH_TOKEN" -H "Accept: application/vnd.github+json")
    local new_sha
    new_sha=$(git rev-parse HEAD)
    log_info "Target commit: $new_sha"
    log_info "Tag: $RELEASE_TAG | Title: $RELEASE_TITLE"

    # --- 1. 删除所有旧 release + 同名旧 tag 引用 (API, 幂等) ---
    log_info "Deleting all existing releases and tag '$RELEASE_TAG'..."
    if ! python3 - "$repo" "$AUTH_TOKEN" "$RELEASE_TAG" <<'PY'
import json, subprocess, sys, urllib.parse
repo, tok, tag = sys.argv[1:4]
H = ["-H", "Authorization: token " + tok, "-H", "Accept: application/vnd.github+json"]
def curl(*args):
    return subprocess.run(["curl", "-sS", "--connect-timeout", "15", *args],
                          capture_output=True, text=True).stdout
resp = curl(*H, "https://api.github.com/repos/" + repo + "/releases?per_page=100")
try:
    releases = json.loads(resp)
except Exception:
    print("Could not list existing releases (response below)", file=sys.stderr)
    print(resp[:300], file=sys.stderr)
    sys.exit(1)
n = 0
for r in releases:
    rid = r.get("id")
    if rid:
        curl("-X", "DELETE", *H, "https://api.github.com/repos/" + repo + "/releases/" + str(rid))
        n += 1
print("old releases deleted: " + str(n))
# 同名 tag 引用一并删除 (幂等: 引用不存在时 API 返回 422, 忽略)
ref = urllib.parse.quote("tags/" + tag, safe="")
curl("-X", "DELETE", *H, "https://api.github.com/repos/" + repo + "/git/refs/" + ref)
PY
    then
        abort "Failed deleting old releases/tag — release creation stopped"
    fi

    # --- 2. 创建 draft release (tag 由 API 自动创建在 new_sha 上) ---
    log_info "Creating draft release..."
    local release_id
    release_id=$(python3 - "$RELEASE_NOTES" "$RELEASE_TAG" "$RELEASE_TITLE" "$new_sha" "$repo" "$AUTH_TOKEN" <<'PY'
import json, subprocess, sys
notes_path, tag, title, sha, repo, tok = sys.argv[1:7]
try:
    notes = open(notes_path, encoding="utf-8").read()
except Exception as e:
    print("Cannot read release notes: " + str(e), file=sys.stderr)
    sys.exit(2)
payload = json.dumps({
    "tag_name": tag,
    "target_commitish": sha,
    "name": title,
    "body": notes,
    "draft": True,
}, ensure_ascii=False)
r = subprocess.run([
    "curl", "-sS", "--connect-timeout", "15", "--max-time", "60",
    "-X", "POST",
    "-H", "Authorization: token " + tok,
    "-H", "Accept: application/vnd.github+json",
    "-H", "Content-Type: application/json",
    "-d", payload,
    "https://api.github.com/repos/" + repo + "/releases",
], capture_output=True, text=True)
try:
    j = json.loads(r.stdout)
except Exception:
    print("Release create failed (non-JSON response below)", file=sys.stderr)
    print(r.stdout[:500], file=sys.stderr)
    sys.exit(1)
if "id" not in j:
    print("Release create failed: " + j.get("message", "unknown"), file=sys.stderr)
    sys.exit(1)
print(j["id"])
PY
) || abort "GitHub release creation failed (see message above). Nothing published."

    # --- 3. 上传附件 (原名; 每附件重试 3 次; 校验 state=uploaded 且 size 一致) ---
    if [[ -n "$RELEASE_ASSET_LIST" ]]; then
        local n_assets_gh
        n_assets_gh=$(wc -l < "$RELEASE_ASSET_LIST" | tr -d ' ')
        log_info "Uploading $n_assets_gh asset(s)..."
        if ! python3 - "$release_id" "$RELEASE_ASSET_LIST" "$repo" "$AUTH_TOKEN" <<'PY'
import json, os, subprocess, sys, urllib.parse
rid, listfile, repo, tok = sys.argv[1:5]
api = "https://uploads.github.com/repos/" + repo + "/releases/" + rid + "/assets?name="
paths = [l for l in (s.strip() for s in open(listfile, encoding="utf-8")) if l]
total = len(paths)
ok = fail = 0
for idx, path in enumerate(paths, 1):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    print("  [{}/{}] {} ({:.1f} MiB) ...".format(idx, total, name, size/1048576), end="", flush=True)
    good = False
    last_err = ""
    for attempt in range(3):
        r = subprocess.run([
            "curl", "-sS", "--connect-timeout", "15", "--max-time", "1800",
            "-H", "Authorization: token " + tok,
            "-H", "Content-Type: application/octet-stream",
            "--data-binary", "@" + path,
            api + urllib.parse.quote(name, safe=""),
        ], capture_output=True, text=True)
        try:
            j = json.loads(r.stdout)
        except Exception:
            j = {}
        if r.returncode == 0 and j.get("state") == "uploaded" and int(j.get("size", -1)) == size:
            good = True
            break
        last_err = j.get("state", j.get("message", "unknown"))
    if good:
        ok += 1
        print("\r  [{}/{}] {} ({:.1f} MiB) ... \u2713 OK".format(idx, total, name, size/1048576), flush=True)
    else:
        fail += 1
        print("\r  [{}/{}] {} ({:.1f} MiB) ... \u2717 FAILED ({})".format(idx, total, name, size/1048576, last_err), flush=True)
print("assets uploaded=" + str(ok) + " failed=" + str(fail), flush=True)
sys.exit(1 if fail else 0)
PY
        then
            log_error "Asset upload failed — release left as DRAFT (not public)."
            log_error "Fix the failed asset and re-run, or publish the draft manually at:"
            log_error "  https://github.com/$GIT_REMOTE_USER/$GIT_REMOTE_REPO/releases"
            exit 1
        fi
    else
        log_info "No assets requested — skipping upload"
    fi

    # --- 4. 发布 (draft -> public) ---
    log_info "Publishing release..."
    local pub_resp
    pub_resp=$(curl -sS --connect-timeout 15 --max-time 60 -X PATCH \
        "${auth_header[@]}" -H "Content-Type: application/json" \
        -d '{"draft":false}' \
        "$api_root/repos/$repo/releases/$release_id") || abort "Publish PATCH request failed"
    if ! echo "$pub_resp" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d.get("draft") is False and d.get("id")) else 1)'; then
        log_error "Publish verification failed (response below):"
        echo "$pub_resp" | head -5 | sed 's/^/    /'
        log_error "Release left as DRAFT. Publish manually or re-run."
        exit 1
    fi

    git tag -f "$RELEASE_TAG" "$new_sha" >/dev/null 2>&1 || true
    log_ok "Release published: https://github.com/$repo/releases/tag/$RELEASE_TAG"
}

# 重建 GitHub Releases: 保存旧 release 的 (name, body, tag_name, draft/prerelease flags),
# 删除所有旧 release，然后以当前 HEAD 重建它们。
# 这样 release 页面的"源码压缩包 (Source code)"会指向新的唯一 commit。
# 要求: AUTH_TOKEN (PAT) 已设置。
rebuild_releases() {
    log_section "Rebuild GitHub Releases"

    if [[ -z "${AUTH_TOKEN:-}" ]]; then
        log_warn "AUTH_TOKEN not set — skipping rebuild_releases (called from execute() guard, should not reach here)"
        return
    fi

    local api_root="https://api.github.com"
    local repo="$GIT_REMOTE_USER/$GIT_REMOTE_REPO"
    local auth_header=(-H "Authorization: token $AUTH_TOKEN" -H "Accept: application/vnd.github+json")
    local new_sha
    new_sha=$(git rev-parse HEAD)
    log_info "Rebuild target commit: $new_sha"

    # 1. 拉取所有旧 release
    log_info "Fetching existing releases..."
    local releases_json
    releases_json=$(run_with_timeout 10 curl -sS "${auth_header[@]}" "$api_root/repos/$repo/releases?per_page=100" 2>&1)
    if ! echo "$releases_json" | grep -q '"id"'; then
        log_warn "Could not fetch releases (response below):"
        echo "$releases_json" | head -5 | sed 's/^/    /'
        return
    fi

    # 解析: tag_name -> JSON 块
    # 用 python 是最稳的方式，避免 bash JSON 解析边角
    local backup_file
    backup_file=$(mktemp -t zen_releases.XXXXXX.json)

    python3 - "$backup_file" <<PYEOF
import json, sys
with open(sys.argv[1], "w") as f:
    data = json.loads('''$releases_json''')
    out = []
    for r in data:
        out.append({
            "tag_name": r.get("tag_name", ""),
            "name": r.get("name", ""),
            "body": r.get("body", ""),
            "draft": r.get("draft", False),
            "prerelease": r.get("prerelease", False),
            "id": r.get("id"),
        })
    json.dump(out, f, ensure_ascii=False, indent=2)
print(f"Saved {len(out)} releases")
PYEOF

    local count
    count=$(python3 -c "import json,sys; print(len(json.load(open('$backup_file'))))" 2>/dev/null || echo 0)
    log_info "Found $count existing releases"

    # 2. 删除所有旧 release (按 id)
    if [[ "$count" -gt 0 ]]; then
        log_info "Deleting old releases..."
        python3 -c "
import json, subprocess
releases = json.load(open('$backup_file'))
for r in releases:
    rid = r['id']
    if rid is None: continue
    subprocess.run(['curl','-sS','-X','DELETE',
                    '-H','Authorization: token $AUTH_TOKEN',
                    '-H','Accept: application/vnd.github+json',
                    'https://api.github.com/repos/$repo/releases/$rid'])
" 2>&1 | head -5
        log_ok "Old releases deleted"
    fi

    # 3. 在新 commit 上重建每个 release (按 tag_name 重新打 tag)
    if [[ "$count" -gt 0 ]]; then
        log_info "Re-creating tags on new commit $new_sha..."
        python3 -c "
import json, subprocess
releases = json.load(open('$backup_file'))
for r in releases:
    tag = r['tag_name']
    if tag:
        subprocess.run(['git','tag', tag, '$new_sha'], cwd='.')
" 2>&1
        log_info "Pushing new tags..."
        GIT_SSH_COMMAND='ssh -o ServerAliveInterval=10 -o ServerAliveCountMax=30 -o TCPKeepAlive=yes' \
            git push --force origin --tags 2>&1 | tail -10 | sed 's/^/    /'

        log_info "Re-creating releases..."
        python3 -c "
import json, subprocess, urllib.parse
releases = json.load(open('$backup_file'))
for r in releases:
    tag = r['tag_name']
    if not tag: continue
    payload = {
        'tag_name': tag,
        'name': r['name'],
        'body': r['body'],
        'draft': r['draft'],
        'prerelease': r['prerelease'],
        'target_commitish': '$new_sha',
    }
    subprocess.run([
        'curl','-sS','-X','POST',
        '-H','Authorization: token $AUTH_TOKEN',
        '-H','Accept: application/vnd.github+json',
        '-H','Content-Type: application/json',
        '-d', json.dumps(payload, ensure_ascii=False),
        'https://api.github.com/repos/$repo/releases'
    ])
" 2>&1 | tail -10
        log_ok "Releases re-created (with new source tarballs pointing to $new_sha)"
    else
        log_info "No releases to rebuild"
    fi

    rm -f "$backup_file"
}

# =============================================================================
# 验证: 轮询直到远端完全反映本地状态
# =============================================================================
# 每 10 秒检查远端，等待 refs/heads/<branch> == 本地 HEAD 且 tag 数 == 期望值。
# 默认 timeout 5 分钟，可通过 VERIFY_TIMEOUT 环境变量调整。
# 覆盖式进度条轮询远端，等待 refs/heads/<branch> == 本地 HEAD 且 tag 数 == 期望值
# 每次心跳 ≤ 8s (timeout)，整体最长 VERIFY_TIMEOUT 秒
verify() {
    log_section "Verification"

    local local_sha
    local_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -z "$local_sha" ]]; then
        log_warn "No local commit to verify"
        return
    fi
    log_ok "Local HEAD: $local_sha"

    local expected_tag_count=0
    if [[ "$RELEASE_ENABLED" == true && "$KEEP_TAGS" == false ]]; then
        expected_tag_count=1   # 旧 tag 全删, 仅剩 release API 自动创建的 tag
    elif [[ "$RELEASE_ENABLED" == true && "$KEEP_TAGS" == true ]]; then
        expected_tag_count=-1  # 旧 tag 保留 + 新 release tag, 总数不可预知 -> 只验证 main
    elif [[ "$KEEP_TAGS" == true ]]; then
        expected_tag_count=$(run_with_timeout 8 git ls-remote --tags \
                             "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" 2>/dev/null \
                             | grep -c refs/tags/ || echo 0)
    fi
    log_info "Expected remote tag count: $expected_tag_count"

    local start_ts
    start_ts=$(now)
    local remote_sha=""
    local tag_count=-1

    while true; do
        local elapsed=$(( $(now) - start_ts ))
        if (( elapsed >= VERIFY_TIMEOUT )); then
            printf "\n"
            log_error "Verification timeout after ${VERIFY_TIMEOUT}s"
            log_error "Final state: remote_main=${remote_sha:-<empty>} (want=$local_sha) | remote_tags=$tag_count (want=$expected_tag_count)"
            return 1
        fi

        # 实际完成判断: 远端 main == 本地 HEAD 且 tag 数 == 期望值
        local refs_out
        refs_out=$(run_with_timeout 8 git ls-remote \
                   "git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git" 2>/dev/null || echo "")

        remote_sha=$(echo "$refs_out" | awk -v branch="refs/heads/$GIT_REMOTE_BRANCH" '$2 == branch {print $1}')
        tag_count=$(echo "$refs_out" | awk '$2 ~ /^refs\/tags\//' | wc -l | tr -d ' ')

        local main_match=false
        [[ "$remote_sha" == "$local_sha" ]] && main_match=true

        # 进度条: 用 elapsed / VERIFY_TIMEOUT 算百分比 (仅供人看, 时间预算)
        # ETA = VERIFY_TIMEOUT - elapsed (纯时间预算)
        local percent=$(( elapsed * 100 / VERIFY_TIMEOUT ))
        local eta_sec=$(( VERIFY_TIMEOUT - elapsed ))
        (( eta_sec < 0 )) && eta_sec=0
        local elapsed_hms eta_hms
        elapsed_hms=$(fmt_duration "$elapsed")
        eta_hms=$(fmt_duration "$eta_sec")
        local status="main=$([ "$main_match" = true ] && echo "OK" || echo "wait") tags=$tag_count/$expected_tag_count"
        progress_render "verify" "$percent" "$elapsed_hms" "$status" "$eta_hms"

        if $main_match && { [[ "$expected_tag_count" -lt 0 ]] || [[ "$tag_count" == "$expected_tag_count" ]]; }; then
            progress_finish "verify" "$elapsed_hms" "ALL CHECKS PASSED"
            # main 同步成功后再做 author 检查
            verify_author
            return 0
        fi

        sleep 5
    done
}

# Author 验证: 确认远端 main 上的 commit author = qhgary
# 防止 AI 工具通过 shell 注入 GIT_AUTHOR_* 导致 author 污染
verify_author() {
    local remote_url="git@github.com:${GIT_REMOTE_USER}/${GIT_REMOTE_REPO}.git"

    # fetch 远端 main 到本地 FETCH_HEAD (只读, 不污染本地分支)
    if ! run_with_timeout 15 git fetch --depth=1 "$remote_url" "$GIT_REMOTE_BRANCH" 2>/dev/null; then
        log_warn "verify_author: fetch failed (timeout or auth)"
        return
    fi

    local remote_sha="$local_sha"
    log_info "Remote HEAD author:"
    git -c color.ui=never log -1 --format='  author    %an <%ae>%n  committer %cn <%ce>%n  message   %s' FETCH_HEAD 2>&1 | sed 's/^/    /'

    local actual_author
    actual_author=$(git log -1 --format='%an <%ae>' FETCH_HEAD 2>/dev/null)

    if [[ "$actual_author" == "$GIT_USER_NAME <$GIT_USER_EMAIL>" ]]; then
        log_ok "Author check PASSED: $actual_author"
    else
        log_error "Author check FAILED — commit author is NOT qhgary!"
        log_error "Expected: $GIT_USER_NAME <$GIT_USER_EMAIL>"
        log_error "Got:      $actual_author"
        AUTHOR_MISMATCH=true
    fi
}

# =============================================================================
# Gitee 同步阶段: 推代码 + 发布同版本 release。
# 依赖 GITEE_TOKEN (私人令牌, 需 projects 写权限), 仅当设置了 GITEE_TOKEN 时由 execute() 调用。
# 附件上传走官方 gitee-release-cli 同款接口 POST /releases/{id}/attach_files (multipart)。
# Gitee 无 draft: 建 release 即公开; 故"先建新 -> 传附件 -> 再删旧", 保证 download/latest/ 不中断。
# =============================================================================
push_to_gitee() {
    log_section "Gitee: Sync Code (force-mirror)"
    local push_url="https://${GITEE_REMOTE_USER}:${GITEE_TOKEN}@gitee.com/${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}.git"
    local repo_api="https://gitee.com/api/v5/repos/${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}"

    # 确保 release tag 存在于本地 (push tags 时一并推上去)
    if [[ -n "$RELEASE_TAG" ]]; then
        git tag -f "$RELEASE_TAG" HEAD >/dev/null 2>&1 || true
    fi

    # 1) 强制同步所有分支 + 所有 tag (GitHub SSH push_with_progress 的 HTTPS 镜像版)
    #    进度条样式与 GitHub push 完全一致 (覆盖式 \r 进度条 + 速率 + ETA)
    log_info "Force pushing all branches + tags to Gitee (${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}@${GITEE_REMOTE_BRANCH}) ..."
    if ! gitee_push_with_progress "$push_url"; then
        return 1
    fi

    # 2) 设置默认分支为本分支 (必须在删除旧 ref 前设, 否则 Gitee 拒删当前默认分支)
    curl -sS --connect-timeout 15 --max-time 60 -X PATCH \
        -H "Content-Type: application/json" \
        -d "{\"default_branch\":\"${GITEE_REMOTE_BRANCH}\"}" \
        "${repo_api}?access_token=${GITEE_TOKEN}" >/dev/null 2>&1 \
        && log_ok "Gitee default branch -> ${GITEE_REMOTE_BRANCH}" \
        || log_warn "Could not update Gitee default branch (may already be correct)"

    # 3) 删除 Gitee 上有、本地没有的分支/tag (等价网页"同步: 删除远程多余的 ref")
    log_info "Pruning extra Gitee refs not present locally ..."
    local tmp_refs
    tmp_refs=$(mktemp -t zen_gitee_refs.XXXXXX)
    git ls-remote --heads --tags "$push_url" 2>/dev/null | awk '{print $2}' | sed 's#^refs/##' > "$tmp_refs" || true
    local local_refs
    local_refs=$(git for-each-ref --format='%(refname)' refs/heads/ refs/tags/ 2>/dev/null | sed 's#^refs/##')
    local deleted=0
    local ref
    while IFS= read -r ref; do
        [[ -z "$ref" ]] && continue
        if ! printf '%s\n' "$local_refs" | grep -qx "$ref"; then
            log_info "  Deleting Gitee ref: $ref"
            git push --delete "$push_url" "refs/$ref" 2>&1 | tail -2 | sed 's/^/    /'
            deleted=$((deleted+1))
        fi
    done < "$tmp_refs"
    rm -f "$tmp_refs"
    log_info "Pruned $deleted extra ref(s) on Gitee"

    log_ok "Gitee code + tags synced OK"
}

publish_gitee_release() {
    log_section "Gitee: Publish Release"
    local api="https://gitee.com/api/v5/repos/${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}"
    local auth="access_token=${GITEE_TOKEN}"
    local gh_push_url="https://${GITEE_REMOTE_USER}:${GITEE_TOKEN}@gitee.com/${GITEE_REMOTE_USER}/${GITEE_REMOTE_REPO}.git"
    local local_sha
    local_sha=$(git rev-parse HEAD)
    log_info "Tag: $RELEASE_TAG | Title: $RELEASE_TITLE | Commit: $local_sha"

    local notes
    notes=$(cat "$RELEASE_NOTES" 2>/dev/null) || { log_error "Cannot read $RELEASE_NOTES"; return 1; }

    # 幂等保护: 若同 tag 已有 release (上次脚本中断 / 手动建 / 旧版本残留),
    # POST /releases 会返回 "该标签已经存在发行版" 直接失败, 这里先 DELETE 掉。
    # Gitee DELETE 端点只接数值 release id (不接 tag), 用 GET /releases/tags/{tag} 查 id。
    # 没有时返回 404, 不影响后续。
    log_info "Deleting any existing release for tag $RELEASE_TAG (idempotency) ..."
    local stale_rid
    stale_rid=$(curl -sS --connect-timeout 15 --max-time 60 \
        "${api}/releases/tags/${RELEASE_TAG}?${auth}" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    j=json.loads(sys.stdin.read()); print(j.get("id",""))
except Exception:
    pass' 2>/dev/null || true)
    if [[ -n "$stale_rid" ]]; then
        curl -sS --connect-timeout 15 --max-time 60 -X DELETE \
            "${api}/releases/${stale_rid}?${auth}" >/dev/null 2>&1 \
            && log_ok "Stale release id=$stale_rid for tag $RELEASE_TAG deleted" \
            || log_warn "Could not delete stale release id=$stale_rid (will fail below if API still rejects)"
    fi

    # 记录现有 release (用于"除新外全删")；空仓库返回 []。
    local releases_json
    releases_json=$(curl -sS --connect-timeout 15 --max-time 60 "$api/releases?${auth}&per_page=100" 2>/dev/null || echo "[]")

    # 创建新 release (先建, 保证 latest 立即指向新版本)。Gitee 无 draft, 创建即公开。
    log_info "Creating Gitee release $RELEASE_TAG ..."
    local release_id
    release_id=$(python3 - "$RELEASE_TAG" "$RELEASE_TITLE" "$notes" "$local_sha" "$api" "$auth" <<'PY'
import json, subprocess, sys
tag, title, notes, sha, api, auth = sys.argv[1:7]
payload = json.dumps({
    "tag_name": tag,
    "target_commitish": sha,
    "name": title,
    "body": notes,
    "prerelease": False,
}, ensure_ascii=False)
r = subprocess.run(["curl", "-sS", "--connect-timeout", "15", "--max-time", "60", "-X", "POST",
    "-H", "Content-Type: application/json", "-d", payload,
    api + "/releases?" + auth], capture_output=True, text=True)
try:
    j = json.loads(r.stdout)
except Exception:
    print("Release create failed (non-JSON): " + r.stdout[:300], file=sys.stderr)
    sys.exit(1)
if "id" not in j:
    print("Release create failed: " + j.get("message", "unknown"), file=sys.stderr)
    sys.exit(1)
print(j["id"])
PY
) || { log_error "Gitee release create failed."; return 1; }
    release_id=$(printf '%s' "$release_id" | tr -d '[:space:]')
    log_ok "Gitee release created id=$release_id"

    # 上传附件 (multipart file + access_token query param, 官方 CLI 同款端点)
    if [[ -n "$RELEASE_ASSET_LIST" ]]; then
        local n_assets_gitee
        n_assets_gitee=$(wc -l < "$RELEASE_ASSET_LIST" | tr -d ' ')
        log_info "Uploading $n_assets_gitee Gitee attachment(s)..."
        if ! python3 - "$release_id" "$RELEASE_ASSET_LIST" "$api" "$GITEE_TOKEN" <<'PY'
import os, subprocess, sys
rid, listfile, api, tok = sys.argv[1:5]
paths = [l for l in (s.strip() for s in open(listfile, encoding="utf-8")) if l]
total = len(paths)
ok = fail = 0
for idx, path in enumerate(paths, 1):
    name = os.path.basename(path)
    size = os.path.getsize(path)
    print("  [{}/{}] {} ({:.1f} MiB) ...".format(idx, total, name, size/1048576), end="", flush=True)
    good = False
    last_code = ""
    for attempt in range(3):
        p = subprocess.run(["curl", "-sS", "--connect-timeout", "15", "--max-time", "1800",
            "-o", "/dev/null", "-w", "%{http_code}",
            "-F", "file=@" + path,
            api + "/releases/" + rid + "/attach_files?access_token=" + tok], capture_output=True, text=True)
        last_code = p.stdout.strip()
        if last_code in ("200", "201", "202"):
            good = True
            break
    if good:
        ok += 1
        print("\r  [{}/{}] {} ({:.1f} MiB) ... \u2713 OK (HTTP {})".format(idx, total, name, size/1048576, last_code), flush=True)
    else:
        fail += 1
        print("\r  [{}/{}] {} ({:.1f} MiB) ... \u2717 FAILED (HTTP {})".format(idx, total, name, size/1048576, last_code or "n/a"), flush=True)
print("attachments uploaded=" + str(ok) + " failed=" + str(fail), flush=True)
sys.exit(1 if fail else 0)
PY
        then
            log_error "Gitee attachment upload FAILED for some files."
            log_error "Release page already exists: https://gitee.com/$GITEE_REMOTE_USER/$GITEE_REMOTE_REPO/releases/tag/$RELEASE_TAG"
            log_error "Upload remaining files manually there."
            return 1
        fi
    else
        log_info "No assets requested — skipping Gitee attachment upload"
    fi

    # 删除旧的 Gitee release (保留新建的) + 旧 tag 引用, 使 Gitee 只留本次新版本
    log_info "Removing old Gitee releases (keep $RELEASE_TAG)..."
    python3 - "$releases_json" "$release_id" "$RELEASE_TAG" "$api" "$auth" <<'PY'
import json, subprocess, sys
data, keep_id, keep_tag, api, auth = sys.argv[1:6]
try:
    releases = json.loads(data)
except Exception:
    releases = []
deleted = 0
for r in releases:
    rid = r.get("id")
    if rid is not None and str(rid) != str(keep_id):
        subprocess.run(["curl", "-sS", "-X", "DELETE", f"{api}/releases/{rid}?{auth}"], capture_output=True)
        deleted += 1
print("deleted " + str(deleted) + " old release(s)")
PY

    local old_tags
    old_tags=$(printf '%s' "$releases_json" | python3 -c "import json,sys
try:
    rs = json.load(sys.stdin)
except Exception:
    rs = []
keep = '$RELEASE_TAG'
print('\n'.join(r.get('tag_name','') for r in rs if r.get('tag_name') and r['tag_name'] != keep))" 2>/dev/null)
    if [[ -n "$old_tags" ]]; then
        while IFS= read -r t; do
            [[ -z "$t" ]] && continue
            log_info "  Deleting old Gitee tag: $t"
            git push --delete "$gh_push_url" "refs/tags/$t" 2>&1 | sed 's/^/    /'
        done <<< "$old_tags"
    fi

    log_ok "Gitee release published: https://gitee.com/$GITEE_REMOTE_USER/$GITEE_REMOTE_REPO/releases/tag/$RELEASE_TAG"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    local main_start_ts
    main_start_ts=$(now)
    local main_start_iso
    main_start_iso=$(date '+%Y-%m-%d %H:%M:%S %Z')

    log_section "reinit_repo.sh"
    log_info "Repo:   $GIT_REMOTE_USER/$GIT_REMOTE_REPO"
    log_info "Branch: $GIT_REMOTE_BRANCH"
    log_info "User:   $GIT_USER_NAME <$GIT_USER_EMAIL>"
    log_info "Commit: $GIT_COMMIT_MSG"
    log_info "Mode:   $(if $DRY_RUN; then echo 'DRY-RUN'; elif $KEEP_TAGS; then 'EXEC (keep-tags)'; else echo 'EXEC (delete-tags)'; fi)"
    log_info "Verify timeout: ${VERIFY_TIMEOUT}s (override via VERIFY_TIMEOUT env)"
    if [[ -n "$RELEASE_TAG" ]]; then
        log_info "Release: tag=$RELEASE_TAG title='$RELEASE_TITLE'"
        log_info "Release notes: $RELEASE_NOTES | assets: ${RELEASE_ASSETS:-<none>}"
    fi
    log_info "Started at: $main_start_iso"

    local rc=0
    preflight_release || rc=$?
    if [[ $rc -eq 0 ]]; then
        confirm_target || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        probe_environment || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        execute || rc=$?
    fi
    if [[ $rc -eq 0 ]]; then
        verify || rc=$?
    fi

    local main_end_ts
    main_end_ts=$(now)
    local main_end_iso
    main_end_iso=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local total_elapsed=$(( main_end_ts - main_start_ts ))

    log_section "Summary"
    log_info "Started:  $main_start_iso"
    log_info "Ended:    $main_end_iso"
    log_info "Total:    $(fmt_duration $total_elapsed)"
    log_info "Exit:     $rc"

    # Author 检查总结
    if [[ "$AUTHOR_MISMATCH" == true ]]; then
        log_error "Remote HEAD author is NOT qhgary. Check your shell env for GIT_AUTHOR_*."
    else
        log_ok "Author check: qhgary confirmed on remote HEAD."
    fi

    if [[ "$RELEASE_ENABLED" == true && $rc -eq 0 ]]; then
        log_ok "Release: https://github.com/$GIT_REMOTE_USER/$GIT_REMOTE_REPO/releases/tag/$RELEASE_TAG"
    elif [[ -n "$RELEASE_TAG" && "$RELEASE_ENABLED" == false ]]; then
        log_warn "Release: SKIPPED (no valid PAT or user choice) — page not created"
    fi

    if [[ -n "${GITEE_TOKEN:-}" && -n "$RELEASE_TAG" && $rc -eq 0 ]]; then
        log_ok "Gitee:   https://gitee.com/$GITEE_REMOTE_USER/$GITEE_REMOTE_REPO/releases/tag/$RELEASE_TAG"
    elif [[ -n "$RELEASE_TAG" && -z "${GITEE_TOKEN:-}" ]]; then
        log_info "Gitee:   skipped (no GITEE_TOKEN)"
    fi

    if [[ $rc -ne 0 ]]; then
        exit $rc
    fi
}

main "$@"
