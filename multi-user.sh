#!/bin/bash
# =========================================
# 作者: jinqians
# 日期: 2025年2月
# 网站：jinqians.com
# 描述: 这个脚本用于管理 Snell 代理的多用户配置
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"

# 定义目录和文件路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本.${RESET}"
        exit 1
    fi
}

# 检查 Snell 是否已安装
check_snell_installed() {
    if ! command -v snell-server &> /dev/null; then
        echo -e "${RED}未检测到 Snell 安装，请先安装 Snell。${RESET}"
        exit 1
    fi
}

# 获取系统DNS
get_system_dns() {
    # 尝试从resolv.conf获取系统DNS
    if [ -f "/etc/resolv.conf" ]; then
        system_dns=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | tr '\n' ',' | sed 's/,$//')
        if [ ! -z "$system_dns" ]; then
            echo "$system_dns"
            return 0
        fi
    fi
    
    # 如果无法从resolv.conf获取，尝试使用公共DNS
    echo "1.1.1.1,8.8.8.8"
}

# 获取用户输入的 DNS 服务器
get_dns() {
    read -rp "请输入 DNS 服务器地址 (直接回车使用系统DNS): " custom_dns
    if [ -z "$custom_dns" ]; then
        DNS=$(get_system_dns)
        echo -e "${GREEN}使用系统 DNS 服务器: $DNS${RESET}"
    else
        DNS=$custom_dns
        echo -e "${GREEN}使用自定义 DNS 服务器: $DNS${RESET}"
    fi
}

# 开放端口 (ufw 和 iptables)
open_port() {
    local PORT=$1
    # 检查 ufw 是否已安装
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中开放端口 $PORT${RESET}"
        ufw allow "$PORT"/tcp
    fi

    # 检查 iptables 是否已安装
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中开放端口 $PORT${RESET}"
        iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
        
        # 创建 iptables 规则保存目录（如果不存在）
        if [ ! -d "/etc/iptables" ]; then
            mkdir -p /etc/iptables
        fi
        
        # 尝试保存规则，如果失败则不中断脚本
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

# 关闭端口 (ufw 和 iptables)
close_port() {
    local PORT=$1
    if command -v ufw &> /dev/null; then
        echo -e "${CYAN}在 UFW 中关闭端口 $PORT${RESET}"
        ufw delete allow "$PORT"/tcp 2>/dev/null
    fi
    if command -v iptables &> /dev/null; then
        echo -e "${CYAN}在 iptables 中删除端口 $PORT 规则${RESET}"
        iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# 检查端口是否被系统其它进程占用 (优先 ss，回退 netstat)
check_system_port() {
    local port=$1
    if command -v ss &> /dev/null; then
        ss -tuln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" && return 0
    elif command -v netstat &> /dev/null; then
        netstat -tuln 2>/dev/null | grep -qE ":${port}([[:space:]]|$)" && return 0
    fi
    return 1
}

# 校验服务是否成功启动
verify_service_started() {
    local service_name=$1
    sleep 1
    systemctl is-active --quiet "$service_name"
}

# 探测 Snell 主版本 (v4/v5)
get_snell_version() {
    if ! command -v snell-server &> /dev/null; then
        echo "4"
        return
    fi
    if snell-server --v 2>&1 | grep -q "v5"; then
        echo "5"
    else
        echo "4"
    fi
}

# 获取服务器公网 IP (多源 + 超时 + 本地路由兜底)
get_server_ip() {
    local services="https://api.ipify.org https://ipv4.icanhazip.com https://ip.sb https://ifconfig.me"
    local ip
    for svc in $services; do
        ip=$(curl -s -4 --connect-timeout 5 --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]')
        case "$ip" in
            *.*.*.*) echo "$ip"; return 0 ;;
        esac
    done
    # IPv4 全部失败时尝试 IPv6
    for svc in $services; do
        ip=$(curl -s -6 --connect-timeout 5 --max-time 8 "$svc" 2>/dev/null | tr -d '[:space:]')
        case "$ip" in
            *:*) echo "$ip"; return 0 ;;
        esac
    done
    # 最后兜底: 本地默认路由源地址
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1)
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    return 1
}

# 根据端口解析配置文件与服务名 (主用户特殊处理)
# 成功时设置全局 RESOLVED_CONF / RESOLVED_SERVICE / RESOLVED_IS_MAIN
resolve_user_by_port() {
    local port=$1
    RESOLVED_CONF=""
    RESOLVED_SERVICE=""
    RESOLVED_IS_MAIN=0
    # 主用户: 配置为 snell-main.conf, 服务为 snell
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        if [ -n "$main_port" ] && [ "$main_port" = "$port" ]; then
            RESOLVED_CONF="${SNELL_CONF_FILE}"
            RESOLVED_SERVICE="snell"
            RESOLVED_IS_MAIN=1
            return 0
        fi
    fi
    # 普通用户
    local user_conf="${SNELL_CONF_DIR}/users/snell-${port}.conf"
    if [ -f "$user_conf" ]; then
        RESOLVED_CONF="$user_conf"
        RESOLVED_SERVICE="snell-${port}"
        RESOLVED_IS_MAIN=0
        return 0
    fi
    return 1
}

# 检查并清理某端口关联的 ShadowTLS 服务
cleanup_shadowtls_for_port() {
    local port=$1
    local stls_service="shadowtls-snell-${port}"
    local stls_file="${SYSTEMD_DIR}/${stls_service}.service"
    if [ -f "$stls_file" ]; then
        echo -e "${YELLOW}检测到端口 ${port} 关联的 ShadowTLS 服务 (${stls_service})${RESET}"
        read -rp "是否一并删除该 ShadowTLS 服务? [y/N]: " stls_choice
        if [[ "$stls_choice" =~ ^[Yy]$ ]]; then
            systemctl stop "$stls_service" 2>/dev/null
            systemctl disable "$stls_service" 2>/dev/null
            rm -f "$stls_file"
            rm -f "/var/log/shadowtls-shadow-tls-snell-${port}.log" 2>/dev/null
            systemctl daemon-reload
            echo -e "${GREEN}关联的 ShadowTLS 服务已删除${RESET}"
        else
            echo -e "${YELLOW}已保留 ShadowTLS 服务，但其后端 127.0.0.1:${port} 即将失效，请自行处理${RESET}"
        fi
    fi
}

# 获取主用户端口
get_main_port() {
    if [ -f "${SNELL_CONF_FILE}" ]; then
        local main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
        echo "$main_port"
    fi
}

# 获取所有用户端口
get_all_ports() {
    # 检查用户配置目录是否存在
    if [ ! -d "${SNELL_CONF_DIR}/users" ]; then
        return 1
    fi
    
    # 获取所有配置文件中的端口
    for conf_file in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
        if [ -f "$conf_file" ]; then
            grep -E '^listen' "$conf_file" | sed -n 's/.*::0:\([0-9]*\)/\1/p'
        fi
    done | sort -n | uniq
}

# 列出所有用户
list_users() {
    echo -e "\n${YELLOW}=== 当前用户列表 ===${RESET}"
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        local count=0
        for user_conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            if [ -f "$user_conf" ]; then
                count=$((count + 1))
                local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
                local tag=""
                if [[ "$user_conf" == *"snell-main.conf" ]]; then
                    tag=" ${CYAN}(主用户)${RESET}"
                fi
                echo -e "${GREEN}用户 $count:${RESET}${tag}"
                echo -e "端口: ${port}"
                echo -e "PSK: ${psk}"
                echo -e "配置文件: ${user_conf}\n"
            fi
        done
        if [ $count -eq 0 ]; then
            echo -e "${YELLOW}当前没有配置的用户${RESET}"
        fi
    else
        echo -e "${YELLOW}当前没有配置的用户${RESET}"
    fi
}

# 检查端口是否已被使用
check_port_usage() {
    local port=$1
    # 检查是否被其他 snell 实例使用 (users/ 目录已包含主用户 snell-main.conf)
    if [ -d "${SNELL_CONF_DIR}/users" ]; then
        for conf in "${SNELL_CONF_DIR}/users"/snell-*.conf; do
            if [ -f "$conf" ]; then
                local used_port=$(grep -E '^listen' "$conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
                if [ "$used_port" = "$port" ]; then
                    return 1
                fi
            fi
        done
    fi
    # 检查系统层面是否被其它进程占用
    if check_system_port "$port"; then
        return 1
    fi
    return 0
}

# 添加新用户
add_user() {
    echo -e "\n${YELLOW}=== 添加新用户 ===${RESET}"
    
    # 创建用户配置目录
    mkdir -p "${SNELL_CONF_DIR}/users"
    
    # 获取端口号
    while true; do
        read -rp "请输入新用户端口号 (1-65535): " PORT
        if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
            # 检查端口是否已被使用
            if ! check_port_usage "$PORT"; then
                echo -e "${RED}端口 $PORT 已被使用，请选择其他端口${RESET}"
                continue
            fi
            break
        else
            echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字${RESET}"
        fi
    done
    
    # 生成随机 PSK
    PSK=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
    
    # 获取 DNS 设置
    get_dns
    
    # 创建用户配置文件
    local user_conf="${SNELL_CONF_DIR}/users/snell-${PORT}.conf"
    cat > "$user_conf" << EOF
[snell-server]
listen = ::0:${PORT}
psk = ${PSK}
ipv6 = true
dns = ${DNS}
EOF
    
    # 创建用户服务文件
    local service_name="snell-${PORT}"
    local service_file="${SYSTEMD_DIR}/${service_name}.service"
    cat > "$service_file" << EOF
[Unit]
Description=Snell Proxy Service (Port ${PORT})
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=${INSTALL_DIR}/snell-server -c ${user_conf}
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server-${PORT}

[Install]
WantedBy=multi-user.target
EOF

    # 重载 systemd 配置
    systemctl daemon-reload
    
    # 启用并启动服务
    systemctl enable "$service_name"
    systemctl start "$service_name"

    # 校验服务是否真正启动
    if ! verify_service_started "$service_name"; then
        echo -e "${RED}服务 ${service_name} 启动失败，正在回滚...${RESET}"
        echo -e "${YELLOW}请用以下命令查看原因: journalctl -u ${service_name} -n 30 --no-pager${RESET}"
        systemctl disable "$service_name" 2>/dev/null
        rm -f "$service_file" "$user_conf"
        systemctl daemon-reload
        return 1
    fi

    # 开放端口
    open_port "$PORT"

    echo -e "\n${GREEN}用户添加成功！配置信息：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}端口: ${PORT}${RESET}"
    echo -e "${YELLOW}PSK: ${PSK}${RESET}"
    echo -e "${YELLOW}配置文件: ${user_conf}${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
}

# 删除用户
delete_user() {
    echo -e "\n${YELLOW}=== 删除用户 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要删除的用户端口
    read -rp "请输入要删除的用户端口号: " del_port

    if [ -z "$del_port" ]; then
        echo -e "${RED}端口号不能为空${RESET}"
        return 1
    fi

    if ! resolve_user_by_port "$del_port"; then
        echo -e "${RED}未找到端口为 ${del_port} 的用户${RESET}"
        return 1
    fi

    # 保护主用户: 不允许在此删除, 避免破坏主服务
    if [ "$RESOLVED_IS_MAIN" = "1" ]; then
        echo -e "${RED}端口 ${del_port} 属于主用户，无法在多用户管理中删除。${RESET}"
        echo -e "${YELLOW}如需卸载主服务，请使用主安装脚本的卸载功能。${RESET}"
        return 1
    fi

    # 删除前确认
    echo -e "${YELLOW}即将删除端口 ${del_port} 的用户 (服务 ${RESOLVED_SERVICE}, 配置 ${RESOLVED_CONF})${RESET}"
    read -rp "确认删除? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}已取消删除${RESET}"
        return 0
    fi

    # 停止并禁用服务
    systemctl stop "$RESOLVED_SERVICE" 2>/dev/null
    systemctl disable "$RESOLVED_SERVICE" 2>/dev/null

    # 删除服务文件
    rm -f "${SYSTEMD_DIR}/${RESOLVED_SERVICE}.service"
    rm -f "/lib/systemd/system/${RESOLVED_SERVICE}.service"
    # 删除配置文件
    rm -f "$RESOLVED_CONF"

    # 重载 systemd 配置
    systemctl daemon-reload

    # 关闭防火墙端口
    close_port "$del_port"

    # 检查并清理关联的 ShadowTLS 服务
    cleanup_shadowtls_for_port "$del_port"

    echo -e "${GREEN}用户已成功删除${RESET}"
}

# 修改用户配置
modify_user() {
    echo -e "\n${YELLOW}=== 修改用户配置 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要修改的用户端口
    read -rp "请输入要修改的用户端口号: " mod_port

    if [ -z "$mod_port" ]; then
        echo -e "${RED}端口号不能为空${RESET}"
        return 1
    fi

    if ! resolve_user_by_port "$mod_port"; then
        echo -e "${RED}未找到端口为 ${mod_port} 的用户${RESET}"
        return 1
    fi

    local user_conf="$RESOLVED_CONF"
    local service_name="$RESOLVED_SERVICE"
    local is_main="$RESOLVED_IS_MAIN"

    echo -e "\n${YELLOW}请选择要修改的项目：${RESET}"
    echo -e "${GREEN}1.${RESET} 修改端口"
    echo -e "${GREEN}2.${RESET} 重置 PSK"
    echo -e "${GREEN}3.${RESET} 修改 DNS"
    echo -e "${GREEN}0.${RESET} 返回"

    read -rp "请输入选项 [0-3]: " mod_choice
    case "$mod_choice" in
        1)
            # 修改端口
            while true; do
                read -rp "请输入新端口号 (1-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ]; then
                    if ! check_port_usage "$new_port"; then
                        echo -e "${RED}端口 $new_port 已被使用，请选择其他端口${RESET}"
                        continue
                    fi
                    break
                else
                    echo -e "${RED}无效端口号，请输入 1 到 65535 之间的数字${RESET}"
                fi
            done

            # 停止服务
            systemctl stop "$service_name"

            # 修改配置文件中的端口
            sed -i "s/listen = ::0:${mod_port}/listen = ::0:${new_port}/" "$user_conf"

            if [ "$is_main" = "1" ]; then
                # 主用户: 配置文件名与服务名固定，不重命名，直接重启 snell
                systemctl daemon-reload
                systemctl restart "$service_name"
                if ! verify_service_started "$service_name"; then
                    echo -e "${RED}主服务重启失败，请检查: journalctl -u ${service_name} -n 30 --no-pager${RESET}"
                    return 1
                fi
            else
                # 普通用户: 重命名配置文件与服务文件
                local new_conf="${SNELL_CONF_DIR}/users/snell-${new_port}.conf"
                local new_service="snell-${new_port}"
                mv "$user_conf" "$new_conf"
                mv "${SYSTEMD_DIR}/${service_name}.service" "${SYSTEMD_DIR}/${new_service}.service"

                # 更新服务文件内容 (使用 | 作 sed 分隔符以避免路径中的 / 冲突)
                sed -i "s/Description=Snell Proxy Service (Port ${mod_port})/Description=Snell Proxy Service (Port ${new_port})/" "${SYSTEMD_DIR}/${new_service}.service"
                sed -i "s/SyslogIdentifier=snell-server-${mod_port}/SyslogIdentifier=snell-server-${new_port}/" "${SYSTEMD_DIR}/${new_service}.service"
                sed -i "s|${user_conf}|${new_conf}|" "${SYSTEMD_DIR}/${new_service}.service"

                # 重载配置并启动服务
                systemctl daemon-reload
                systemctl enable "$new_service"
                systemctl start "$new_service"
                if ! verify_service_started "$new_service"; then
                    echo -e "${RED}服务 ${new_service} 启动失败，请检查: journalctl -u ${new_service} -n 30 --no-pager${RESET}"
                    return 1
                fi
            fi

            # 开放新端口、关闭旧端口
            open_port "$new_port"
            close_port "$mod_port"

            # 旧端口若关联了 ShadowTLS，提示处理
            cleanup_shadowtls_for_port "$mod_port"

            echo -e "${GREEN}端口修改成功 (${mod_port} -> ${new_port})${RESET}"
            ;;
        2)
            # 重置 PSK
            local new_psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
            sed -i "s/psk = .*/psk = ${new_psk}/" "$user_conf"
            systemctl restart "$service_name"
            echo -e "${GREEN}PSK 已重置为: ${new_psk}${RESET}"
            ;;
        3)
            # 修改 DNS
            get_dns
            sed -i "s/dns = .*/dns = ${DNS}/" "$user_conf"
            systemctl restart "$service_name"
            echo -e "${GREEN}DNS 修改成功${RESET}"
            ;;
        0)
            return
            ;;
        *)
            echo -e "${RED}无效选项${RESET}"
            ;;
    esac
}

# 显示用户配置信息
show_user_config() {
    echo -e "\n${YELLOW}=== 用户配置信息 ===${RESET}"
    
    # 显示用户列表
    list_users
    
    # 获取要查看的用户端口
    read -rp "请输入要查看的用户端口号: " view_port

    if [ -z "$view_port" ]; then
        echo -e "${RED}端口号不能为空${RESET}"
        return 1
    fi

    if ! resolve_user_by_port "$view_port"; then
        echo -e "${RED}未找到端口为 ${view_port} 的用户${RESET}"
        return 1
    fi

    local user_conf="$RESOLVED_CONF"
    local port=$(grep -E '^listen' "$user_conf" | sed -n 's/.*::0:\([0-9]*\)/\1/p')
    local psk=$(grep -E '^psk' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
    local dns=$(grep -E '^dns' "$user_conf" | awk -F'=' '{print $2}' | tr -d ' ')
    local snell_ver=$(get_snell_version)

    echo -e "\n${GREEN}用户配置详情：${RESET}"
    echo -e "${CYAN}--------------------------------${RESET}"
    echo -e "${YELLOW}端口: ${port}${RESET}"
    echo -e "${YELLOW}PSK: ${psk}${RESET}"
    echo -e "${YELLOW}DNS: ${dns}${RESET}"
    echo -e "${YELLOW}版本: v${snell_ver}${RESET}"

    # 获取服务器 IP (多源 + 超时 + 兜底)
    local server_ip=$(get_server_ip)
    if [ -n "$server_ip" ]; then
        echo -e "\n${GREEN}Surge 配置：${RESET}"
        echo -e "${GREEN}snell-${port} = snell, ${server_ip}, ${port}, psk = ${psk}, version = ${snell_ver}, reuse = true, tfo = true${RESET}"
    else
        echo -e "${RED}无法获取服务器 IP，请手动填写${RESET}"
    fi

    echo -e "${CYAN}--------------------------------${RESET}"
}

# 主菜单
show_menu() {
    clear
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          Snell 多用户管理${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    
    echo -e "${YELLOW}=== 用户管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} 查看所有用户"
    echo -e "${GREEN}2.${RESET} 添加新用户"
    echo -e "${GREEN}3.${RESET} 删除用户"
    echo -e "${GREEN}4.${RESET} 修改用户配置"
    echo -e "${GREEN}5.${RESET} 查看用户详细配置"
    echo -e "${GREEN}0.${RESET} 退出脚本"
    
    echo -e "${CYAN}============================================${RESET}"
    read -rp "请输入选项 [0-5]: " choice
}

# 初始检查
check_root
check_snell_installed

# 主循环
while true; do
    show_menu
    case "$choice" in
        1)
            list_users
            ;;
        2)
            add_user
            ;;
        3)
            delete_user
            ;;
        4)
            modify_user
            ;;
        5)
            show_user_config
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-5]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按任意键返回主菜单...${RESET}"
    read -n 1 -s -r
done 
