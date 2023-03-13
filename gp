#!/usr/bin/env python3
import json
import time
import fcntl
import urllib.parse
import urllib.request
from os import makedirs, path, getpid, remove
from pathlib import Path
from typing import Dict, Union, Final, List

# Program Constants
CONFIG_LOCATION: Final[Path] = Path.home() / '.config/gp-cmdline-chatgpt.json'

# Model Constants
URL: Final[str] = 'https://api.openai.com/v1/chat/completions'

CONFIG_SCHEMA = {
    'type': 'object',
    'properties': {
        'api_key': {
            'type': 'string'
        },
        'chat_history': {
            'type': 'string',
            'default': '~/.cache/gp-cmdline-chatgpt/'
        },
        'model': {
            'type': 'string',
            'default': 'gpt-3.5-turbo'
        },
        'temperature': {
            'type': 'number',
            'default': 1
        },
        'system_message': {
            'type': 'string',
            'default': 'You are ChatGPT, a large language model trained by OpenAI. Answer as concisely as possible.'
        }
    }
}

ConfigT = Dict[str, Union[str, float]]


class ChatState:
    def __init__(self, config: ConfigT, new: bool = False):
        self.state_dir: Path = Path(path.expanduser(config['chat_history']))
        try:
            makedirs(self.state_dir)  # ensure dir exists
        except FileExistsError:
            pass

        self.lock_path: Path = self.state_dir / '.gp-cmdline-chatgpt.lock'
        self.lock_file = open(self.lock_path, 'w')

        # error raised if lock cannot be obtained
        fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.lock_file.write(str(getpid()))

        self.state_file: Path = self.state_dir / '.state.json'
        if new or not self.state_file.exists():
            self.id: int = int(time.time())
        else:
            with open(self.state_file) as f:
                self.id = json.load(f)['active_chat_id']
        self.chat_file: Path = self.state_dir / f'{self.id}.jsonlines'
        self._new_messages: List[Dict[str, str]] = []
        self._messages = []
        if self.chat_file.exists():
            with open(self.chat_file) as f:
                for line in f:
                    self._messages.append(json.loads(line))
        else:
            self._new_messages.append(ChatState._message('system', config['system_message']))

    @staticmethod
    def _message(role: str, content: str):
        return {'role': role, 'content': content}

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        with open(self.state_file, 'w') as f:
            json.dump({'active_chat_id': self.id}, f)

        # TODO: make update only
        with open(self.chat_file, 'a') as f:
            for msg in self._new_messages: 
                f.write(json.dumps(msg) + '\n')

        fcntl.flock(self.lock_file, fcntl.LOCK_UN)
        self.lock_file.close()
        remove(self.lock_path)

    def messages(self) -> List[Dict[str, str]]:
        return self._messages + self._new_messages

    def add_user_message(self, message: str):
        self._new_messages.append(ChatState._message('user', message))

    def add_message(self, message: Dict[str, str]):
        self._new_messages.append(message)


def configuration() -> ConfigT:
    assert CONFIG_LOCATION.exists(), f'configuration file must be located at a {CONFIG_LOCATION}'

    with open(CONFIG_LOCATION) as f:
        config = json.load(f)
    assert isinstance(config, dict), 'configuration must be a json object'
    for k, v in CONFIG_SCHEMA['properties'].items():
        if 'default' not in v:
            assert k in config, f'{k} is a required field in the configuration'
        else:
            config[k] = config.get(k, v['default'])
        if v['type'] == 'string':
            assert isinstance(config[k], str), f'{k}, must be of type {v["type"]}'
        elif v['type'] == 'number':
            try:
                config[k] = float(config[k])
            except ValueError:
                raise AssertionError(f'{k}, must be of type {v["type"]}')
        else:
            raise AssertionError(f'{v["type"]} is not a supported type')

    return config


def headers(config: ConfigT) -> Dict[str, str]:
    return {'Content-Type': 'application/json', 'Authorization': f'Bearer {config["api_key"]}'}


def send_chat(msg: str, config: ConfigT, new_chat: bool = False):
    with ChatState(config, new=new_chat) as state:
        state.add_user_message(msg)
        payload = {'model': config['model'], 'temperature': config['temperature'], 'messages': state.messages()}
        data = json.dumps(payload).encode('utf-8')
        request = urllib.request.Request(URL, data, headers=headers(config), method='POST')
        response = json.loads(urllib.request.urlopen(request).read())
        response_message = response['choices'][0]['message']
        state.add_message(response_message)
    return response_message['content']


if __name__ == "__main__":
    from argparse import ArgumentParser

    parser = ArgumentParser(
        prog='Commandline ChatGPT',
        description='Uses the ChatGPT API to allow interacting from the commandline')
    parser.add_argument('message', nargs='*', type=str)
    parser.add_argument('-n', '--new', action='store_true', help='Starts a new ChatGPT Session')
    parser.add_argument('-r', '--resume_session', type=int, help='Resume an old session by giving that sessions id')
    args = parser.parse_args()
    config = configuration()
    print(send_chat(' '.join(args.message), config, args.new))
    # print(send_chat("and how many people are there?", config))
