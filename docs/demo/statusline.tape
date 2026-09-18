# Regenerate the README statusline GIF:  vhs docs/demo/statusline.tape
Output docs/statusline-demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1000
Set Height 340
Set Padding 24
Set TypingSpeed 60ms

Hide
Type "source docs/demo/statusline-setup.sh && clear"
Enter
Show

Sleep 800ms
Type "bash statusline/segment.sh --full < ~/session.json"
Sleep 400ms
Enter
Sleep 2.5s

Type "cp ~/narrow-layout.cprof.json ~/.cprof.json"
Sleep 400ms
Enter
Sleep 600ms
Type "bash statusline/segment.sh --full < ~/session.json"
Sleep 400ms
Enter
Sleep 2.5s

Type "cp ~/bad-width.cprof.json ~/.cprof.json"
Sleep 400ms
Enter
Sleep 600ms
Type "cprof doctor"
Sleep 400ms
Enter
Sleep 3.5s
