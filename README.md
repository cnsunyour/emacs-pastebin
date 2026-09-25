# Emacs Pastebin Interface

This is a huge inteface to pastebin.com. With it you can

- Paste buffers
- Fetch pastes
- Delete pastes
- Get a nice list of pastes
- Sort the pastes list by data, title, private, format, key

## Install

- Unpack the repo on ~/.emacs.d/lisp, create it if needed
- Run make to compile it (optional)
- Put it on path on your .emacs file
- Restart emacs

```bash
mkdir ~/.emacs.d/lisp/
cd ~/.emacs.d/lisp/
wget https://github.com/cnsunyour/emacs-pastebin/archive/master.zip
unzip master.zip
rm master.zip
cd emacs-pastebin-master/
make
```

Then put this on your `.emacs` file:

```elisp
(add-to-list 'load-path "~/.emacs.d/lisp/emacs-pastebin-master/")
(require 'neopastebin)
(let ((credentials (auth-source-user-and-password "pastebin.com")))
  (pastebin-create-login :username "YOURUSER"
                         :dev-key (car credentials)
                         :password (cadr credentials)))
```

Or, use `use-package` like this:

```elisp
(use-package neopastebin
  :load-path "~/.emacs.d/lisp/emacs-pastebin-master/"
  :defer t
  :commands
  pastebin-list-buffer-refresh
  pastebin-new
  :config
  (let ((credentials (auth-source-user-and-password "pastebin.com")))
    (pastebin-create-login :username "YOURUSER"
                           :dev-key (car credentials)
                           :password (cadr credentials))))
```

Before that, you should store `dev-key` and `password` in the `~/.authinfo.gpg` file:

```text
machine pastebin.com login YOURDEVKEY password YOURPASSWORD
```

Restart emacs or eval `.emacs` again. On emacs `M-x pastebin-list-buffer-refresh <RET>`. You should see a nice list of pastes on your screen right now.

## Usage

### Listing

M-x `pastebin-list-buffer-refresh` -> Fetch and list pastes on "list buffer".
After logged you can list your pastes with command `pastebin-list-buffer-refresh`, just type pastebin-l and press TAB.

Here is a list of keybinds from list buffer.

```
RET -> fetch paste and switch to it
r ->   refresh list and list buffer
d ->   delete paste, you'll be asked for confirmation
t ->   order by title
D ->   order by date
f ->   order by format
k ->   order by key
p ->   order by private
```

### Creating a new paste

M-x `pastebin-new` -> will create a new paste from current buffer

The name of the paste is given from current buffer name
The format from buffers major mode
Prefix argument makes the paste unlisted (C-u); without it the paste is public
