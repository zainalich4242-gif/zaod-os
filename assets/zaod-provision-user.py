#!/usr/bin/python3
import json
import os
import pwd
import re
import stat
import subprocess
import sys
from pathlib import Path

USERNAME = re.compile(r'^[a-z][a-z0-9-]{0,31}$')


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        fail(result.stderr.strip() or result.stdout.strip() or f'{args[0]} failed')
    return result


def read_request(path):
    caller = os.environ.get('PKEXEC_UID')
    if not caller or not caller.isdigit():
        fail('Account setup must be authorized through PolicyKit.')
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError as error:
        fail(f'Cannot read setup request: {error}')
    try:
        info = os.fstat(fd)
        if info.st_uid != int(caller) or stat.S_IMODE(info.st_mode) & 0o077:
            fail('Setup request permissions are not secure.')
        with os.fdopen(fd, 'r', encoding='utf-8') as stream:
            payload = json.load(stream)
    except (OSError, ValueError) as error:
        fail(f'Invalid setup request: {error}')
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass
    return payload


def main():
    if os.geteuid() != 0 or len(sys.argv) != 2:
        fail('Usage: pkexec zaod-provision-user <private-request-file>')
    payload = read_request(sys.argv[1])
    username = str(payload.get('username', '')).strip()
    full_name = str(payload.get('full_name', '')).strip()
    password = str(payload.get('password', ''))
    if not USERNAME.fullmatch(username):
        fail('Username must start with a lowercase letter and contain only lowercase letters, digits, or hyphen.')
    if len(full_name) < 2 or len(full_name) > 80 or '\n' in full_name:
        fail('Enter a valid full name.')
    if len(password) < 8 or '\n' in password or ':' in password:
        fail('Password must be at least eight characters and cannot contain a newline or colon.')
    if subprocess.run(['getent', 'passwd', username], capture_output=True).returncode == 0:
        fail('That username already exists.')

    groups = 'sudo,audio,video,plugdev,netdev'
    run(['/usr/sbin/useradd', '--create-home', '--shell', '/bin/bash',
         '--comment', full_name, '--groups', groups, username])
    try:
        subprocess.run(['/usr/sbin/chpasswd'], input=f'{username}:{password}\n',
                       text=True, check=True, capture_output=True)
        home = Path('/home') / username
        if not home.is_dir():
            fail('The user home directory was not created.')
        account = pwd.getpwnam(username)
        os.chown(home, account.pw_uid, account.pw_gid)
        os.chmod(home, 0o700)

        # The preset live account is public knowledge; disable it after setup.
        subprocess.run(['/usr/sbin/usermod', '--lock', 'zaod'], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        temporary_home = Path('/home/zaod')
        if temporary_home.is_dir():
            os.chmod(temporary_home, 0o700)

        lightdm = Path('/etc/lightdm/lightdm.conf.d/50-zaod-autologin.conf')
        lightdm.parent.mkdir(parents=True, exist_ok=True)
        lightdm.write_text(
            '[Seat:*]\n'
            'user-session=xfce\n'
            'greeter-session=lightdm-gtk-greeter\n',
            encoding='utf-8'
        )
        flag = Path('/var/lib/zaod/.onboarding_complete')
        flag.parent.mkdir(parents=True, exist_ok=True)
        flag.write_text(username + '\n', encoding='utf-8')
        os.chmod(flag, 0o600)
    except Exception:
        subprocess.run(['/usr/sbin/userdel', '--remove', username], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise

    print(f'Created account {username}. Sign in at the ZAOD login screen.')


if __name__ == '__main__':
    main()
