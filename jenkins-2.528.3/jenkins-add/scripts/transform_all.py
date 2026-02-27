import os
import re
import glob
from datetime import datetime

# Configuration (Relative paths for portability)
BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE_DIR = os.path.join(os.path.dirname(BASE_DIR), 'origin/jenkins_export_20260223')
TARGET_DIR = os.path.join(BASE_DIR, 'manifests/transformed_pipelines')
REPORT_PATH = os.path.join(BASE_DIR, 'reports/transformation_summary.txt')

# Transformation Rules
URL_MAP = {
    'gitlab.strato.co.kr': 'gitlab.internal.net',
    'harbor-product.strato.co.kr:8443': '1.1.1.213:30002',
    '210.217.178.150': '1.1.1.50'  # Deployment target IP replacement
}

CREDENTIAL_MAP = {
    '10-product-gitlab-Credential': 'gitlab.internal.net',
    '0-harbor(10.10.10.91)-Credential': '0-harbor-product-Credential',
    'gitlab.strato.co.kr': 'gitlab.internal.net'
}

def transform_content(content):
    # 1. Agent change (any -> label)
    content = content.replace('agent any', "agent { label 'jenkins-agent' }")
    
    # 2. URL & IP replacements
    for old, new in URL_MAP.items():
        content = content.replace(old, new)
        
    # 3. Credential ID mappings
    for old_id, new_id in CREDENTIAL_MAP.items():
        content = content.replace(f"credentialsId: '{old_id}'", f"credentialsId: '{new_id}'")
        content = content.replace(f'credentialsId: "{old_id}"', f'credentialsId: "{new_id}"')

    # 4. Advanced Docker Logic Injection (If not already present)
    # Checks for docker.build and injects harborHost normalization if missing
    if 'docker.build' in content and 'def harborHost =' not in content:
        # Simple injection logic for script blocks
        normalization_snippet = """
      // HARBOR_URL 정규화 (scheme 및 trailing slash 제거)
      def harborHost = env.HARBOR_URL
        .trim()
        .replaceFirst(/^https?:\\/\\/(.*)$/, '$1')
        .replaceAll(/\\/+$/, '')
      
      def remoteImage = "${harborHost}/${env.CONTAINER_IMAGE_NAME}"
"""
        # find the line before withDockerRegistry or docker.build
        content = re.sub(r'(script\s*\{)', r'\1' + normalization_snippet, content)

    return content

def analyze_credentials(content):
    tmp = content.replace('&apos;', "'").replace('&quot;', '"')
    pattern = r"credentialsId:\s*['\"]([^'\"]+)['\"]"
    return re.findall(pattern, tmp)

def find_external_ips(content):
    tmp = content.replace('&apos;', "'").replace('&quot;', '"')
    pattern = r"https?://[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|https?://[a-zA-Z0-9.-]+\.strato\.co\.kr"
    return re.findall(pattern, tmp)

def main():
    if not os.path.exists(TARGET_DIR):
        os.makedirs(TARGET_DIR)
    
    xml_files = glob.glob(os.path.join(SOURCE_DIR, "*.xml"))
    all_creds = {}
    external_links = set()
    docker_jobs = 0
    
    print(f">>> Processing {len(xml_files)} files...")
    print(f">>> Source: {SOURCE_DIR}")
    print(f">>> Target: {TARGET_DIR}")
    
    for path in xml_files:
        filename = os.path.basename(path)
        # Group by tenant
        if '_goe' in filename: tenant = 'goe'
        elif '_nhis' in filename: tenant = 'nhis'
        elif '_lgcns' in filename: tenant = 'lgcns'
        else: tenant = 'common'
            
        tenant_dir = os.path.join(TARGET_DIR, tenant)
        if not os.path.exists(tenant_dir):
            os.makedirs(tenant_dir)
        
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
        
        # Analyze
        creds = analyze_credentials(content)
        for c in creds:
            all_creds[c] = all_creds.get(c, 0) + 1
            
        links = find_external_ips(content)
        for l in links:
            is_new = False
            for target in URL_MAP.values():
                if target in l:
                    is_new = True
                    break
            if not is_new:
                external_links.add(l)
        
        if 'docker.build' in content or 'withDockerRegistry' in content:
            docker_jobs += 1
            
        # Transform
        transformed = transform_content(content)
        
        with open(os.path.join(tenant_dir, filename), 'w', encoding='utf-8') as f:
            f.write(transformed)

    # Generate Report
    report_dir = os.path.dirname(REPORT_PATH)
    if not os.path.exists(report_dir):
        os.makedirs(report_dir)
        
    with open(REPORT_PATH, 'w', encoding='utf-8') as f:
        f.write("============================================================\n")
        f.write(" Integrated Jenkins Pipeline Transformation Report\n")
        f.write(f" Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write("============================================================\n\n")
        
        f.write(f"[ Status ]\n")
        f.write(f"  Total XML Files: {len(xml_files)}\n")
        f.write(f"  Pipelines using Docker: {docker_jobs}\n\n")
        
        f.write(f"[ Replacements ]\n")
        for old, new in URL_MAP.items():
            f.write(f"  {old} -> {new}\n")
        f.write("\n")
        
        f.write(f"[ Credentials Summary (After Mapping) ]\n")
        sorted_creds = sorted(all_creds.items(), key=lambda x: x[1], reverse=True)
        for cred, count in sorted_creds:
            f.write(f"  [{count:3}] {cred}\n")
        f.write("\n")
        
        f.write(f"[ External Links Check Required ]\n")
        for link in sorted(list(external_links)):
            f.write(f"  {link}\n")
            
    print(f">>> Complete. Saved to {REPORT_PATH}")

if __name__ == "__main__":
    main()
