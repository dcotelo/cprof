# Regenerate the README usage GIF:  vhs docs/demo/usage.tape
Output docs/usage-demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1000
Set Height 360
Set Padding 24
Set TypingSpeed 60ms

Hide
Type "source docs/demo/usage-setup.sh && clear"
Enter
Show

Sleep 800ms
Type "cprof list"
Sleep 400ms
Enter
Sleep 2.5s

Type "cprof usage personal"
Sleep 400ms
Enter
Sleep 2.5s

Type "cprof doctor"
Sleep 400ms
Enter
Sleep 4s
