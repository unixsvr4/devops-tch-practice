cd devops-tch-practice

# Stage everything
git add .github/ k8s/ terraform/ observability/ Jenkinsfile
git commit -m "feat: full DevSecOps practice stack for TCH interview"
git push origin main

# Verify it's live
gh repo view --web   # opens in browser
