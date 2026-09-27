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
(pastebin-create-login :username "YOURUSER"
                       :dev-key "YOURDEVKEY"
                       :password-auth-source '(:host "pastebin.com" :user "YOURUSER"))
```

Or, use `use-package` like this:

```elisp
(use-package neopastebin
  :load-path "~/.emacs.d/lisp/emacs-pastebin-master/"
  :defer t
  :commands
  pastebin-list-buffer-refresh
  pastebin-new
  pastebin-logout
  :config
  (pastebin-create-login :username "YOURUSER"
                         :dev-key "YOURDEVKEY"
                         :password-auth-source '(:host "pastebin.com" :user "YOURUSER")))
```

Before that, store your password in the `~/.authinfo.gpg` file:

```text
machine pastebin.com login YOURUSER password YOURPASSWORD
```

The `:password-auth-source` spec tells the package how to find that entry:
the password is looked up through `auth-source` only when a login is
actually needed, and it is not kept in memory afterwards. If you prefer not
to have `username`/`dev-key` in your init file either, store each of them
in its own `auth-source` entry and read them at call time with
`auth-source-pick-first-password` - that function returns the entry's
secret, so the value goes into the `password` field of the entry.

Restart emacs or eval `.emacs` again. On emacs `M-x pastebin-list-buffer-refresh <RET>`. You should see a nice list of pastes on your screen right now.

## Security

- With `:password-auth-source` or `:password-function`, the password is
  fetched only when a login happens and is not kept in the user object.
  The legacy `:password` string stays in memory until the first successful
  login clears it, and `username`/`dev-key` are kept for the whole session.
- After a login, the user key (`usr-key`) is kept in memory so later API
  calls don't need to log in again. It is a bearer token: run
  `M-x pastebin-logout` to drop it.
- Do not add `pastebin--default-user` to `desktop-globals-to-save`, and
  keep `url-http-debug` disabled: it can log request data, credentials
  included.
- `auth-source` may keep its own in-memory cache for a couple of hours;
  that is outside the control of this package.

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
