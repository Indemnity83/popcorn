# Records docs/demo.gif. Run docs/demo-setup.sh first, then from the repo
# root: vhs docs/demo.tape (https://github.com/charmbracelet/vhs)
Output docs/demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1000
Set Height 430
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms

Hide
Type "docker exec -it -u forge -w /home/forge demo bash" Enter
Sleep 2s
Type "clear" Enter
Sleep 500ms
Show

Sleep 600ms
Type "sudo popcorn check" Sleep 500ms Enter
Sleep 3.5s

Hide
Type "clear" Enter
Sleep 300ms
Show

Type "sudo systemctl stop nginx" Sleep 400ms Enter
Sleep 1s
Type "sudo popcorn start" Sleep 500ms Enter
Sleep 4.5s
Type "curl -sI https://example.com | head -4" Sleep 500ms Enter
Sleep 4.5s
