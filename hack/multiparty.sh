#!/bin/bash
# set -x

FORWARDED_PORT=5555

script_path=$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )
cd "$script_path"

# Read the compiled bytecode and ABI for the batch pin contract
ABI=$(jq -r -c .abi ./Firefly.json)
BYTECODE=$(jq -r -c .bytecode ./Firefly.json)

# Set up a port forward to the service in the background. We will kill this before the end of the script
kubectl port-forward svc/firefly $FORWARDED_PORT:http &
PORTFORWARD_PID=$!
sleep 1

echo "Deploying contract..."

# Use FireFly's API to deploy the multiparty contract. Retry while the namespace is still initializing (FF10441)
# rather than assuming a fixed sleep is enough for FireFly to come up after the port forward.
for i in $(seq 1 30); do
    RESPONSE=$(curl --location "http://127.0.0.1:$FORWARDED_PORT/api/v1/namespaces/default/contracts/deploy?confirm=true" \
    --header 'Content-Type: application/json' \
    --data '{
        "definition": '$ABI',
        "contract": "'$BYTECODE'"
    }')

    if [[ $(jq -r .error <<< "$RESPONSE") != *"is initializing"* ]]; then
        break
    fi

    echo "Namespace still initializing, retrying..."
    sleep 2
done

kill $PORTFORWARD_PID

echo "Deploy response: $RESPONSE"

# Parse the resposne from FireFly to get the address and block number in which the contract was deployed
ADDRESS=$(jq -r .output.contractLocation.address <<<  $RESPONSE)
BLOCK_NUMBER=$(jq -r .output.protocolId <<< $RESPONSE  | cut -d '/' -f1 | sed 's/^0*//')

echo ADDRESS: $ADDRESS
echo BLOCK_NUMBER: $BLOCK_NUMBER

# Replace the list of deployed multiparty contracts with the one just deployed. Each run targets a fresh
# chain (a new kind cluster / besu genesis), so contracts from a previous run are no longer valid and
# should not be kept around.
yq -i '.config.fireflyContracts = [{"address": "'$ADDRESS'", "firstEvent": "'$BLOCK_NUMBER'"}] | .config.fireflyContracts.[].address style="double"' ./multiparty-values.yaml

# Apply the new values to the FireFly config
helm upgrade --install firefly ../charts/firefly -f ../charts/firefly/local-kind-values.yaml -f ./multiparty-values.yaml --wait


# Wait here until FF comes back up after the config change
kubectl wait --for=condition=ready pod/firefly-0

# Set up a port forward to the service in the background. We will kill this before the end of the script
kubectl port-forward svc/firefly $FORWARDED_PORT:http &
PORTFORWARD_PID=$!
sleep 1

# Check to see if multiparty mode has already been enabled - we will need this later in the script
ORG_REGISTERED=$(curl http://127.0.0.1:$FORWARDED_PORT/api/v1/namespaces/default/status | jq .org.registered)

echo $ORG_REGISTERED
if [ $ORG_REGISTERED == "true" ]
then
    echo "Switching to new contract at $ADDRESS from block $BLOCK_NUMBER..."
    curl --location "http://127.0.0.1:$FORWARDED_PORT/api/v1/network/action" \
        --header 'Content-Type: application/json' \
        --data '{"type": "terminate"}'
else
	echo "Registering org..."
    curl --location "http://127.0.0.1:$FORWARDED_PORT/api/v1/network/organizations/self?confirm=true" \
        --header 'Content-Type: application/json' \
        --data '{}'
    echo "Registering node..."
    curl --location "http://127.0.0.1:$FORWARDED_PORT/api/v1/network/nodes/self?confirm=true" \
        --header 'Content-Type: application/json' \
        --data '{}'
fi

kill $PORTFORWARD_PID
echo "done"