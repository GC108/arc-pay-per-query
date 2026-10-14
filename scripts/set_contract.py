"""Write the deployed contract address (deployments/<mode>.json) into worker/wrangler.toml for that network."""
import json, pathlib, re, sys
mode = sys.argv[1]  # testnet | mainnet
root = pathlib.Path(__file__).resolve().parent.parent
addr = json.loads((root / "deployments" / f"{mode}.json").read_text())["contract"]
assert re.fullmatch(r"0x[0-9a-fA-F]{40}", addr), addr
toml = root / "worker" / "wrangler.toml"
s = toml.read_text()
head, sep, tail = s.partition("[env.mainnet.vars]")
pat = re.compile(r'CONTRACT_ADDRESS = "0x[0-9a-fA-F]{40}"')
if mode == "testnet":
    head, n = pat.subn(f'CONTRACT_ADDRESS = "{addr}"', head, count=1)
else:
    tail, n = pat.subn(f'CONTRACT_ADDRESS = "{addr}"', tail, count=1)
assert n == 1, "CONTRACT_ADDRESS line not found"
toml.write_text(head + sep + tail)
print(f"wrangler.toml [{mode}] CONTRACT_ADDRESS = {addr}")
