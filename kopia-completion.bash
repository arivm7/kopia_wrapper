# kopia-completion.bash
# ------------------------------------------------------------------------------
# Автодополнение bash для kopia_backup.sh и kopia_restore_to.sh.
# Дополняет только имена флагов — пути аргументов (ПУТЬ_ВОССТАНОВЛЕНИЯ,
# ПУТЬ у --info) не подставляются.
#
# Подключается через `source` (например, из ~/.bashrc). Самостоятельно
# не запускается и не требует флага исполнения.
# ------------------------------------------------------------------------------

_kopia_backup_complete() {
    local cur opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="-h --help -u --usage -v --version"
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
}

_kopia_restore_to_complete() {
    local cur opts
    cur="${COMP_WORDS[COMP_CWORD]}"
    opts="-h --help -u --usage -v --version -i --info"
    COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
}

complete -F _kopia_backup_complete kopia_backup.sh
complete -F _kopia_restore_to_complete kopia_restore_to.sh
