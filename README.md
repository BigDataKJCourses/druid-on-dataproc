# *Apache Druid* on *Google Cloud Dataproc*

- https://cloud.google.com/dataproc
- https://druid.apache.org/

*Google Cloud Dataproc* comes with a wide range of pre-installed *Big Data* tools. Additional ones can be easily added either as optional components or using initialization actions (see the [Dataproc 2.2 image documentation](https://cloud.google.com/dataproc/docs/concepts/versioning/dataproc-release-2.2)).  <br>
Unfortunately, ***Apache Druid* is not included** among the available components and must be installed manually.

This repository provides an initialization script and instructions to extend a *Google Cloud Dataproc* cluster with ***Apache Druid***.

> Prerequisites:  
> - You have a staging bucket in your selected region (created by a previous *Dataproc* cluster).  
> - The following environment variables are already defined in your *Cloud Shell* session:
>   - `REGION`
>   - `CLUSTER_NAME`
>   - `PROJECT_ID`
>
> If not, you can set them manually with the following commands: 
> ```bash
> export REGION=europe-west4
> export CLUSTER_NAME=apache-cluster
> export PROJECT_ID=$(gcloud config get-value project)
> ```

## Overview

Before launching the *Dataproc* cluster, you will prepare some additional resources and configuration to include *Apache Druid*. This includes downloading a setup script, uploading it and the *Druid* archive to *Cloud Storage*, and launching the cluster with the right initialization steps.

---

## Step-by-step Instructions

Go to https://console.cloud.google.com/ and activate the *Cloud Shell* – the terminal environment provided by Google Cloud. 

### 1. Identify your staging bucket

Run the following command to find the staging bucket for your region and store it in an environment variable:

```bash
BUCKET=$(gcloud storage buckets list \
  --filter="location=${REGION} AND name~staging" \
  --format="value(name)" \
  | head -n1)
```

### 2. Clone this repository and locate the initialization script

```bash
git clone https://github.com/BigDataKJCourses/druid-on-dataproc.git
cd druid-on-dataproc
```

### 3. Make the script executable and upload it to *Cloud Storage*

```bash
chmod +x druid-init.sh
gsutil cp druid-init.sh gs://${BUCKET}/
```

### 4. Download and upload *Apache Druid*

```bash
export DRUID_VERSION=32.0.1

curl -L https://downloads.apache.org/druid/${DRUID_VERSION}/apache-druid-${DRUID_VERSION}-bin.tar.gz \
  -o apache-druid-${DRUID_VERSION}-bin.tar.gz

gsutil cp apache-druid-${DRUID_VERSION}-bin.tar.gz \
  gs://${BUCKET}/apache-druid-${DRUID_VERSION}-bin.tar.gz
```

If you change the `DRUID_VERSION`, make sure to update it in the `druid-init.sh` script as well.


### 5. Create the *Dataproc* cluster

```bash
gcloud dataproc clusters create ${CLUSTER_NAME} --enable-component-gateway \
  --region ${REGION} --subnet default --public-ip-address \
  --master-machine-type n2-standard-4 --master-boot-disk-size 50 \
  --num-workers 2 --worker-machine-type n2-standard-2 --worker-boot-disk-size 50 \
  --image-version 2.2-debian12 --optional-components ZOOKEEPER,DOCKER \
  --project ${PROJECT_ID} --max-age=3h --metadata "run-on-master=true" \
  --initialization-actions \
  gs://goog-dataproc-initialization-actions-${REGION}/kafka/kafka.sh,gs://${BUCKET}/druid-init.sh
```

Components like *Kafka* and *Docker* are optional, but can be helpful when experimenting with ingestion pipelines or implementing more advanced *Apache Druid* use cases.

### Final

As you probably know, *Apache Druid* is composed of multiple cooperating services: <br>
(see: [Apache Druid Architecture](https://druid.apache.org/docs/32.0.1/design/architecture/))

- *Coordinator* – responsible for segment distribution and management across the cluster.
- *Overlord* – manages task submission and coordination of ingestion.
- *Broker* – routes queries to the appropriate nodes.
- *Historical* – loads segments from deep storage to local disk for fast, analytical queries.
- *MiddleManager* – handles ingestion tasks and distributed processing.
- *Router* – an optional but quite useful service, as it provides a unified web console.

In our setup, the data-related services (like `historical` and `middleManager`) are installed on the worker nodes of the *Dataproc* cluster.<br>
The master and query services (`coordinator-overlord`, `broker`, `router`) run on the master node.

The *Router* service is exposed on port `8095`.
If you establish an SSH tunnel to this port, you’ll be able to access the Druid web console in your browser.

![Druid Services](docs/images/services.png)

### Accessing the *Druid Router Web Console* via SSH Tunnel

1. **Get the preview URL in Cloud Shell (do not open it yet):**

```bash
echo "http://localhost:8095" | cloudshell get-web-preview-url -p 8095
```

This command provides a URL to access port 8095 via Cloud Shell’s web preview. However, do not open this URL yet, as the SSH tunnel is not established.

2. **Create an SSH tunnel to the master node with port forwarding:**

First, get the zone where your master node is running:

```bash
ZONE=$(gcloud compute instances list --filter="name=${CLUSTER_NAME}-m" --format="value(zone)")
```

Then, create the SSH connection and forward the local port 8095 to the master node’s port 8095:

```bash
gcloud compute ssh "${CLUSTER_NAME}-m" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}" \
  -- -L 8095:localhost:8095
```

3. **Open the previously obtained web preview URL:**

Once the SSH tunnel is active, you can open the URL you got from step 1 in your browser to access the *Druid Router's* web interface.

> Note:
> This approach leverages *Cloud Shell's* web preview combined with SSH port forwarding to securely access the Druid Router UI running on your *Dataproc* master node without exposing it publicly.<br>
> Alter

---

## License
This project is licensed under custom terms. See the `LICENSE` file for details.
Use is permitted with proper attribution. Resale or redistribution as part of paid products or services is prohibited.

---

## Attribution
If you reuse or modify this setup, you must include a visible reference to the original repository:
https://github.com/BigDataKJCourses/druid-on-dataproc

---

## Questions?
Open an issue in this repository if you need help or want to suggest improvements.

---

## Was this helpful?
If this guide or script saved you time or helped you solve a problem, consider supporting my work by buying me a coffee:
☕ [Buy me a coffee](https://coff.ee/kjankiewicz)