# shellcheck disable=SC2148
# zsh snippet, meant to be sourced from ~/.zshrc — not a standalone bash script.
# Tmux layout functions (ctdl, ctdlm)
[[ -f ~/.config/tmux/tmux-ctdl/tmux-ctdl.sh ]] && source ~/.config/tmux/tmux-ctdl/tmux-ctdl.sh
alias dev='ctdlm'
