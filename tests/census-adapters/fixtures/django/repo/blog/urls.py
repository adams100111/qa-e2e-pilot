from django.urls import path
urlpatterns = [
    path('<slug:slug>/', views.post, name='post-detail'),
    path('', views.index),
]
