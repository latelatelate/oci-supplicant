# Oracle Cloud Infrastructure Supplicant
An automated way to create Compute Instances using OCI CLI and bash.

Oracle's free tier offers a generous ARM instance with 4 cors and 24gb of memory. Compared to most other services, that is a pretty good free plan to start with. The only problem is that the resources are very limited for users in the free plan. If you want to create an instance through their website, you usually run into an error: **Out of Capacity**. It means that there aren't enough free resources available. Instead of clicking endless times in the browser, we can automate the instance creation request.

**Features**:
- Uses Bash and Linux
- API key authentication without time limits
- Instance customizations via simple `.json` files
- Retries automatically until success
- Basic error logging

## Setup 
1. Install the Oracle cloud CLI for Linux/Unix: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm#InstallingCLI__linux_and_unix
2. Login to your Oracle Cloud account in the browser: https://cloud.oracle.com/
3. Go to Profile -> My Profile (User information OCID) and copy the **user ocid** somewhere
4. Go to Profile -> Tenancy (Tenancy information OCID) and copy the value into the [.env file](.env) in the variable `TENANCY_ID`
5. Go to Profile -> My profile -> API keys 
   - Click on "Add API key" and download the private and public key
6. Configure OCI by running following command in your terminal: `oci setup config`
   - In the console prompt fill in the **user ocid (step 3**) and **tenancy ocid (step 4)**
   - Select your region number (e.g. type in `24` for `eu-frankfurt-1`)
   - Press `n` to use the existing key previously generated
   - Provide the path to the private key file previously downloaded in step 5
   - Config should be written now and we already added the API key in step 5
   - **Note**: In case you are asked for a profile name: Type in "DEFAULT"

7. Execute following command to get a list of possible images. Select one and copy it into the [.env](.env) variable `IMAGE_ID`:
```bash
oci compute image list --all -c "$TENANCY_ID" --auth api_key | jq -r '.data[] | select(.["display-name"] | contains("aarch64")) | "\(.["display-name"]): \(.id)"'
```
8. To get a list of possible Subnets, which you can save in the [.env](.env) variable `SUBNET_ID`:
```bash
oci network subnet list -c "$TENANCY_ID" --auth api_key | jq -r '.data[] | "\(.["display-name"]): \(.id)"'
```
9. Copy the availability domain into the [.env](.env) variable `AVAILABILITY_DOMAIN`:
```bash
oci iam availability-domain list -c "$TENANCY_ID" --auth api_key | jq -r '.data[].name'
```
10. Lastly change the variable `PATH_TO_PUBLIC_SSH_KEY` in the [.env](.env) file. That;s the path to a public SSH key on your machine to connect to the ARM instance once it's created
   - Either download it from the Oracle Cloud instance creation website or [generate an ssh key yourself](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#generating-a-new-ssh-key)  
11. Ensure the `./run.sh` bash script can be executed 
```bash
chmod +x run.sh
```
Setup complete!

## Configuration
oci-supplicant is customizable via run time args
```bash
./run.sh --interval=120 --try=20 --config="config/ampere.max.json"
```
Here is the full list of usable arguments:
<dl>
   <dt>--config=</dt>
   <dd>
      Specifies a `config.json` file to use for instance creation. Config files contain the hardware and image info necessary for instance creation in `json` format. Here is an example of `ampere.max.json` (max specs for free tier):

   ```json
   {
      "shape": "VM.Standard.A1.Flex",
      "shapeConfig": {
         "ocpus": 4,
         "memoryInGBs": 24
      },
      "sourceDetails": {
         "sourceType": "image",
         "imageId": "INCLUDE_YOUR_IMAGE_ID_HERE",
         "bootVolumeSizeInGBs": 50
      }
   }
   ```

   </dd>
   <dd>Specify the distro image to use with imageId. Hard drive size is specified with `bootVolumeSizeInGBs` but keep in mind OCI only gives free tier users 200gb across all instances</dd>
   <dd>Default: config/ampere.default.json</dd>
</dl>
<dl>
   <dt>--interval=</dt>
   <dd>The time interval between retries (in seconds)</dd>
   <dd>Default: 60</dd>
</dl>
<dl>
   <dt>--name=</dt>
   <dd>Name for the instance being created (alias of --display-name)</dd>
   <dd>Default: none</dd>
</dl>
<dl>
   <dt>--profile=</dt>
   <dd>OCI profile to use with API requests.</dd>
   <dd>Default: DEFAULT</dd>
</dl>
<dl>
   <dt>--try</dt>
   <dd>Total number of attempts. Specify `0` for infinite retries</dd>
   <dd>Default: 0 (infinite)</dd>
</dl>

## Usage 

In a linux environment, run the script silently detached from terminal using:

```bash
( nohup ./run.sh --config="config/ampere.max.json" > /dev/null 2>&1 & disown )
```
The script will request an instance every minute (default `--interval`). Errors are logged to `/var/log/oci-launcher.log` (limited to 1000 lines). 

The creation process could take days/weeks/months. I'd recommend running this in the background in a standalone container or virtual machine.