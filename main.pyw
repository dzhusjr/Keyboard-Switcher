import keyboard,ctypes,requests
from bs4 import BeautifulSoup as BS
from plyer import notification, facades, wifi

user32 = ctypes.WinDLL('user32', use_last_error=True)

dictionary = {"q":"й","w":"ц","e":"у","r":"к","t":"е","y":"н","u":"г","i":"ш","o":"щ","p":"з","[":"х","]":"ї","a":"ф","s":"і","d":"в","f":"а","g":"п","h":"р","j":"о","k":"л","l":"д",";":"ж","'":"є","z":"я","x":"ч","c":"с","v":"м","b":"и","n":"т","m":"ь",",":"б",".":"ю"}
last_word = ""
last_triggerd = ""
active = True
ENG = 67699721
UKR = -257424350

def add_key(key):
    global last_word, last_triggerd, active
    key = key.name.lower()
    # if win32gui.GetCursorInfo()[1] != 65541:return #if cursor != I (to somehow detect that you are actually typing, not just gaming or sth) ❗❗❗❗
    current_layout = user32.GetKeyboardLayout(user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), 0)) #autohotkey заважає
    if current_layout != ENG:
        try:key = dictionary[key]
        except:pass
    if key == "space":
        print(last_word+ ": "+last_triggerd)
        if len(last_word) < 3 or " " in last_word or last_word == last_triggerd or not active: last_word = ""; return
        lang = 'ukr'
        try:
            try:transliterated = "".join([dictionary[i] for i in last_word]);lang = 'ukr'
            except:transliterated = "".join([[k for k, v in dictionary.items() if v == i][0] for i in last_word]);lang = 'eng'
        except:return
        
        if lang == 'eng':
            try:result = bool(requests.get(f"https://api.dictionaryapi.dev/api/v2/entries/en/{transliterated}"))
            except:result = False
            if result:
                last_triggerd = last_word
                keyboard.send('ctrl+backspace')
                print("bs")
                keyboard.write(transliterated + " ")
                if current_layout != ENG: 
                    keyboard.send("shift+alt")
                print(last_word)
                print(transliterated)

        elif lang == 'ukr':
            try:
                soup = BS(requests.get(f'https://slovnyk.ua/index.php?swrd={transliterated}').text, 'html.parser')
                result = not bool(soup.find('div',class_ = 'alert alert-danger alert-dismissible'))
            except:result = True
            if result:
                last_triggerd = last_word
                keyboard.send('ctrl+backspace')
                print("bs")
                keyboard.write(transliterated + " ")
                if current_layout != UKR:
                    keyboard.send("shift+alt")
                print(last_word)
                print(transliterated) 
        last_word = ""

    elif key == "backspace": last_word = last_word[:-1]
    elif key == "end": active = False if active else True; print(active); notification.notify(title = "Keyboard-Switcher",message = f'Keyboard-Switcher is {"enabled." if active else "disabled."}')
    elif len(key) == 1: last_word += key
    else: last_word = ""

keyboard.on_release(callback=add_key)
keyboard.wait()