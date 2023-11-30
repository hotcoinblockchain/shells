import subprocess
import re

### lotus net connect /ip4/58.22.103.100/tcp/51235/p2p/12D3KooW9tMrPeMCwwb2SBCZaMKNDhG9Cyd4S5ViuRVCSE6gnsDB

# 执行 lotus net peer 命令获取返回值
result = subprocess.run(["lotus", "net", "peers"], capture_output=True, text=True)
output = result.stdout

# 匹配数据的正则表达式
pattern = r'(\w+), \[(\/ip4\/[^\]]+\/tcp\/\d+)\]'

matches = re.findall(pattern, output)

formatted_data = [f"lotus net connect {match[1]}/p2p/{match[0]}" for match in matches]

for item in formatted_data:
    print(item)


